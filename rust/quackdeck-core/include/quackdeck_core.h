#ifndef QUACKDECK_CORE_H
#define QUACKDECK_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct QdBleSession QdBleSession;
typedef struct QdLanRpcClient QdLanRpcClient;
typedef struct QdSignallingClient QdSignallingClient;

void qd_string_free(char *ptr);

char *qd_gatt_uuids(void);
char *qd_parse_cb_manufacturer_data(const uint8_t *bytes, size_t len);
char *qd_parse_setup_code(const char *raw);

char *qd_ble_session_new(
    const char *psk_hex,
    const char *robot_id,
    size_t mtu,
    QdBleSession **out_handle
);
char *qd_ble_session_feed(
    QdBleSession *handle,
    const uint8_t *bytes,
    size_t len,
    size_t mtu
);
char *qd_ble_session_seal(
    QdBleSession *handle,
    const char *json_line,
    size_t mtu
);
void qd_ble_session_free(QdBleSession *handle);

char *qd_lan_rpc_connect(
    const char *host,
    uint16_t port,
    const char *robot_id,
    const char *psk_hex,
    uint64_t timeout_ms,
    QdLanRpcClient **out_handle
);
char *qd_lan_rpc_call(
    QdLanRpcClient *handle,
    const char *request_json,
    uint64_t timeout_ms
);
void qd_lan_rpc_free(QdLanRpcClient *handle);

char *qd_sig_connect(
    const char *host,
    uint16_t port,
    const char *robot_id,
    const char *psk_hex,
    uint64_t timeout_ms,
    QdSignallingClient **out_handle
);
char *qd_sig_send(QdSignallingClient *handle, const char *text);
char *qd_sig_next_event(QdSignallingClient *handle, uint64_t timeout_ms);
void qd_sig_free(QdSignallingClient *handle);

#ifdef __cplusplus
}
#endif

#endif /* QUACKDECK_CORE_H */
