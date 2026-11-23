use std::ffi::{CString, c_char, c_void};
use std::net::{Ipv4Addr, SocketAddr};
use std::time::Duration;

use idevice::remote_pairing::{PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket};
use tokio::net::TcpListener;
use tokio::sync::{oneshot, watch};
use tokio::time::{sleep, timeout};

use crate::{HOST, RUNTIME, release_to_c};

type Advertise = extern "C" fn(*mut c_void, *const c_char, u32, u16, *const u8, u16) -> bool;
type ShowCode = extern "C" fn(*mut c_void, *const c_char);

pub struct UpdaterPairingCancellation(watch::Sender<bool>);

#[repr(i32)]
enum HostError {
    WifiUnavailable = 1,
    AdvertisementFailed = 2,
    TimedOut = 3,
    Rejected = 4,
    Canceled = 5,
    Unavailable = 6,
}

fn wifi_address() -> Option<(u32, Ipv4Addr)> {
    let mut interfaces = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut interfaces) } != 0 {
        return None;
    }
    let mut result = None;
    let mut cursor = interfaces;
    while let Some(interface) = unsafe { cursor.as_ref() } {
        cursor = interface.ifa_next;
        let address = interface.ifa_addr;
        if address.is_null()
            || unsafe { (*address).sa_family } as i32 != libc::AF_INET
            || interface.ifa_flags & libc::IFF_UP as u32 == 0
        {
            continue;
        }
        let name = unsafe { std::ffi::CStr::from_ptr(interface.ifa_name) };
        if name.to_bytes() != b"en0" {
            continue;
        }
        let address = unsafe { &*address.cast::<libc::sockaddr_in>() };
        let ipv4 = Ipv4Addr::from(address.sin_addr.s_addr.to_ne_bytes());
        let index = unsafe { libc::if_nametoindex(interface.ifa_name) };
        if index != 0 && !ipv4.is_unspecified() && !ipv4.is_loopback() {
            result = Some((index, ipv4));
            break;
        }
    }
    unsafe { libc::freeifaddrs(interfaces) };
    result
}

async fn accept(
    advertise: Advertise,
    show_code: ShowCode,
    context: *mut c_void,
) -> Result<Vec<u8>, HostError> {
    let (interface, address) = wifi_address().ok_or(HostError::WifiUnavailable)?;
    let listener = TcpListener::bind(SocketAddr::from((address, 0)))
        .await
        .map_err(|_| HostError::WifiUnavailable)?;
    let port = listener
        .local_addr()
        .map_err(|_| HostError::Unavailable)?
        .port();
    let mut host = PairableHostInfo::generate(HOST, "Mac17,7");
    let mut pairing = RpPairingFile::generate(&format!("{HOST}:{:02x?}", host.alt_irk));
    host.identifier.clone_from(&pairing.identifier);
    let service_id =
        CString::new(pairing.identifier.as_str()).map_err(|_| HostError::Unavailable)?;
    let mut txt = Vec::new();
    for (key, value) in host.mdns_txt_records(&pairing.identifier) {
        let entry = format!("{key}={value}");
        let length = u8::try_from(entry.len()).map_err(|_| HostError::Unavailable)?;
        txt.push(length);
        txt.extend_from_slice(entry.as_bytes());
    }
    let txt_len = u16::try_from(txt.len()).map_err(|_| HostError::Unavailable)?;
    if !advertise(context, service_id.as_ptr(), interface, port, txt.as_ptr(), txt_len) {
        return Err(HostError::AdvertisementFailed);
    }

    let stream = timeout(Duration::from_secs(120), async {
        loop {
            let (stream, peer) = listener.accept().await.map_err(|_| HostError::Unavailable)?;
            if peer.ip() == address && wifi_address() == Some((interface, address)) {
                return Ok(stream);
            }
        }
    })
    .await
    .map_err(|_| HostError::TimedOut)??;
    drop(listener);

    let mut responder = PairableHost::new(RpPairingSocket::new_device(stream), host);
    let response = {
        let (displayed, code_request) = oneshot::channel();
        let exchange = responder.accept(&mut pairing, |code| async move {
            if let Ok(code) = CString::new(code) {
                show_code(context, code.as_ptr());
                let _ = displayed.send(());
            }
        });
        tokio::pin!(exchange);
        tokio::select! {
            biased;
            result = &mut exchange => result,
            Ok(()) = code_request => timeout(Duration::from_secs(90), &mut exchange)
                .await
                .map_err(|_| HostError::TimedOut)?,
            _ = sleep(Duration::from_secs(20)) => return Err(HostError::TimedOut),
        }
    };
    response.map_err(|_| HostError::Rejected)?;
    Ok(pairing.to_bytes())
}

#[unsafe(no_mangle)]
pub extern "C" fn updater_pairing_cancel_new() -> *mut UpdaterPairingCancellation {
    Box::into_raw(Box::new(UpdaterPairingCancellation(watch::channel(false).0)))
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn updater_pairing_cancel(cancel: *const UpdaterPairingCancellation) {
    if let Some(cancel) = unsafe { cancel.as_ref() } {
        cancel.0.send_replace(true);
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn updater_pairing_cancel_free(cancel: *mut UpdaterPairingCancellation) {
    if !cancel.is_null() {
        drop(unsafe { Box::from_raw(cancel) });
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn updater_pairing_accept(
    cancel: *const UpdaterPairingCancellation,
    advertise: Option<Advertise>,
    show_code: Option<ShowCode>,
    context: *mut c_void,
    record_out: *mut *mut u8,
    record_len: *mut usize,
) -> i32 {
    let Some(cancel) = (unsafe { cancel.as_ref() }) else {
        return HostError::Unavailable as i32;
    };
    let (Some(advertise), Some(show_code)) = (advertise, show_code) else {
        return HostError::Unavailable as i32;
    };
    if record_out.is_null() || record_len.is_null() {
        return HostError::Unavailable as i32;
    }
    let Some(runtime) = RUNTIME.get_or_init(|| tokio::runtime::Runtime::new().ok()) else {
        return HostError::Unavailable as i32;
    };
    let mut cancellation = cancel.0.subscribe();
    if *cancellation.borrow() {
        return HostError::Canceled as i32;
    }
    let result = runtime.block_on(async {
        tokio::select! {
            biased;
            result = accept(advertise, show_code, context) => result,
            _ = cancellation.wait_for(|canceled| *canceled) => Err(HostError::Canceled),
        }
    });
    match result {
        Ok(record) => {
            unsafe { (*record_out, *record_len) = release_to_c(record) };
            0
        }
        Err(error) => error as i32,
    }
}
