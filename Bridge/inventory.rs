mod updater_pairing_host;

use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::os::fd::AsRawFd;
use std::sync::OnceLock;
use std::time::Duration;

use idevice::remote_pairing::{
    RemotePairingClient, RpPairingFile, RpPairingSocket, connect_tls_psk_tunnel_native,
};
use idevice::rsd::RsdHandshake;
use idevice::services::installation_proxy::InstallationProxyClient;
use idevice::tcp::adapter::Adapter;
use idevice::{IdeviceError, RsdService};
use tokio::net::{TcpSocket, TcpStream};
use tokio::time::timeout;

const HOST: &str = "Sideload Updater";
const DEVICE_VPN_ADDRESS: [u8; 4] = [10, 7, 0, 1];
static RUNTIME: OnceLock<Option<tokio::runtime::Runtime>> = OnceLock::new();

#[repr(i32)]
enum InventoryStatus {
    LoopbackUnavailable = 1,
    PairingRejected = 2,
    InvalidRecord = 3,
    InventoryUnavailable = 4,
}

async fn connect_loopback(port: u16) -> Result<TcpStream, IdeviceError> {
    let socket = TcpSocket::new_v4()?;
    let destination = SocketAddr::from((DEVICE_VPN_ADDRESS, port));
    let index = loopback_interface(destination)?;
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::IPPROTO_IP,
            libc::IP_BOUND_IF,
            (&raw const index).cast(),
            std::mem::size_of_val(&index) as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    timeout(
        Duration::from_secs(4),
        socket.connect(destination),
    )
    .await
    .map_err(|_| IdeviceError::Timeout)?
    .map_err(Into::into)
}

fn loopback_interface(destination: SocketAddr) -> Result<u32, IdeviceError> {
    let route = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0))?;
    route.connect(destination)?;
    let source = route.local_addr()?.ip();
    let mut interfaces = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut interfaces) } != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    let mut index = 0;
    let mut cursor = interfaces;
    while let Some(interface) = unsafe { cursor.as_ref() } {
        cursor = interface.ifa_next;
        let address = interface.ifa_addr;
        if address.is_null() || unsafe { (*address).sa_family } as i32 != libc::AF_INET {
            continue;
        }
        let address = unsafe { &*address.cast::<libc::sockaddr_in>() };
        let name = unsafe { std::ffi::CStr::from_ptr(interface.ifa_name) };
        if interface.ifa_flags & libc::IFF_UP as u32 != 0
            && name.to_bytes().starts_with(b"utun")
            && source == Ipv4Addr::from(address.sin_addr.s_addr.to_ne_bytes())
        {
            index = unsafe { libc::if_nametoindex(interface.ifa_name) };
            break;
        }
    }
    unsafe { libc::freeifaddrs(interfaces) };
    if index == 0 {
        return Err(IdeviceError::InternalError("loopback VPN unavailable".into()));
    }
    Ok(index)
}

async fn read_apps(
    mut pairing: RpPairingFile,
    port: u16,
    create_pairing: bool,
) -> Result<(Vec<u8>, Option<Vec<u8>>), InventoryStatus> {
    let stream = connect_loopback(port)
        .await
        .map_err(|_| InventoryStatus::LoopbackUnavailable)?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), HOST);

    let pairing_timeout = if create_pairing { 90 } else { 8 };
    timeout(Duration::from_secs(pairing_timeout), async {
        rpc.attempt_pair_verify().await?;
        if create_pairing {
            rpc.pair_with_pin(&mut pairing, || async { Err(IdeviceError::CanceledByUser) }).await
        } else {
            rpc.validate_pairing(&mut pairing).await
        }
    })
    .await
    .map_err(|_| InventoryStatus::PairingRejected)?
    .map_err(|_| InventoryStatus::PairingRejected)?;

    let apps = timeout(Duration::from_secs(15), async {
        let tunnel_port = rpc.create_tcp_listener().await?;
        let stream = connect_loopback(tunnel_port).await?;
        let tunnel = connect_tls_psk_tunnel_native(stream, rpc.encryption_key()).await?;
        let client_address = tunnel
            .info
            .client_address
            .parse()
            .map_err(|_| IdeviceError::FfiInvalidArg)?;
        let server_address = tunnel
            .info
            .server_address
            .parse()
            .map_err(|_| IdeviceError::FfiInvalidArg)?;
        let mtu = tunnel.info.mtu as usize;
        let rsd_port = tunnel.info.server_rsd_port;
        let mut adapter = Adapter::new(Box::new(tunnel.into_inner()), client_address, server_address);
        adapter.set_mss(mtu.saturating_sub(60));
        let mut adapter = adapter.to_async_handle();
        let stream = adapter
            .connect(rsd_port)
            .await
            .map_err(|error| IdeviceError::InternalError(error.to_string()))?;
        let mut handshake = RsdHandshake::new(stream).await?;
        let mut proxy = InstallationProxyClient::connect_rsd(&mut adapter, &mut handshake).await?;
        let attributes = [
            "CFBundleIdentifier",
            "CFBundleDisplayName",
            "CFBundleName",
            "CFBundleShortVersionString",
            "SignerIdentity",
            "Entitlements",
            "ProfileValidated",
            "IsDeveloperApp",
            "isDeveloperApp",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        proxy
            .get_apps_with_attributes(Some("User"), None, Some(attributes))
            .await
    })
    .await
    .map_err(|_| InventoryStatus::InventoryUnavailable)?
    .map_err(|_| InventoryStatus::InventoryUnavailable)?;

    let mut data = Vec::new();
    plist::to_writer_binary(&mut data, &apps).map_err(|_| InventoryStatus::InventoryUnavailable)?;
    Ok((data, create_pairing.then(|| pairing.to_bytes())))
}

fn release_to_c(data: Vec<u8>) -> (*mut u8, usize) {
    let mut data = data.into_boxed_slice();
    let result = (data.as_mut_ptr(), data.len());
    std::mem::forget(data);
    result
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn updater_inventory_read(
    port: u16,
    record: *const u8,
    record_len: usize,
    apps_out: *mut *mut u8,
    apps_len: *mut usize,
    record_out: *mut *mut u8,
    record_out_len: *mut usize,
) -> i32 {
    if apps_out.is_null() || apps_len.is_null() || record_out.is_null() || record_out_len.is_null() {
        return InventoryStatus::InventoryUnavailable as i32;
    }
    if port == 0 || record.is_null() != (record_len == 0) || record_len > 128 * 1024 {
        return InventoryStatus::InvalidRecord as i32;
    }

    let creates_pairing = record.is_null();
    let pairing = if creates_pairing {
        RpPairingFile::generate(HOST)
    } else {
        match RpPairingFile::from_bytes(unsafe { std::slice::from_raw_parts(record, record_len) }) {
            Ok(pairing) => pairing,
            Err(_) => return InventoryStatus::InvalidRecord as i32,
        }
    };

    let runtime = RUNTIME.get_or_init(|| tokio::runtime::Runtime::new().ok());
    let Some(runtime) = runtime else {
        return InventoryStatus::InventoryUnavailable as i32;
    };
    match runtime.block_on(read_apps(pairing, port, creates_pairing)) {
        Ok((apps, record)) => {
            unsafe {
                (*apps_out, *apps_len) = release_to_c(apps);
                if let Some(record) = record {
                    (*record_out, *record_out_len) = release_to_c(record);
                }
            }
            0
        }
        Err(status) => status as i32,
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn updater_inventory_free(bytes: *mut u8, size: usize) {
    if !bytes.is_null() {
        let slice = std::ptr::slice_from_raw_parts_mut(bytes, size);
        drop(unsafe { Box::from_raw(slice) });
    }
}
