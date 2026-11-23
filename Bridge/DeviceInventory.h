#ifndef UPDATER_DEVICE_INVENTORY_H
#define UPDATER_DEVICE_INVENTORY_H

#include <stdbool.h>
#include <stdint.h>

int32_t updater_inventory_read(uint16_t port, const uint8_t *record, uintptr_t record_len,
                               uint8_t **apps_out, uintptr_t *apps_len,
                               uint8_t **record_out, uintptr_t *record_out_len);

void updater_inventory_free(uint8_t *bytes, uintptr_t size);

typedef struct UpdaterPairingCancellation UpdaterPairingCancellation;

typedef bool (*UpdaterAdvertisePairing)(void *context, const char *service_name,
                                      uint32_t interface_index, uint16_t port,
                                      const uint8_t *txt, uint16_t txt_length);
typedef void (*UpdaterShowPairingCode)(void *context, const char *code);

UpdaterPairingCancellation *updater_pairing_cancel_new(void);
void updater_pairing_cancel(const UpdaterPairingCancellation *cancel);
void updater_pairing_cancel_free(UpdaterPairingCancellation *cancel);
int32_t updater_pairing_accept(const UpdaterPairingCancellation *cancel,
                               UpdaterAdvertisePairing advertise,
                               UpdaterShowPairingCode show_code, void *context,
                               uint8_t **record_out, uintptr_t *record_len);

#endif
