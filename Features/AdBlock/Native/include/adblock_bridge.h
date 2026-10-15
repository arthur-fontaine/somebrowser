// C API of the adblock_bridge crate (src/lib.rs) over Brave's adblock-rust.
#include <stddef.h>
#include <stdint.h>

typedef struct AdbEngine AdbEngine;

AdbEngine *adb_engine_new(const char *lists);
AdbEngine *adb_engine_deserialize(const uint8_t *data, size_t len);
uint8_t *adb_engine_serialize(const AdbEngine *engine, size_t *len);
void adb_bytes_free(uint8_t *data, size_t len);
void adb_engine_free(AdbEngine *engine);
int32_t adb_engine_use_resources(AdbEngine *engine, const char *json);
void adb_string_free(char *s);
int32_t adb_check(const AdbEngine *engine, const char *url, const char *source_url, const char *request_type,
                  char **redirect, char **rewritten);
char *adb_cosmetic(const AdbEngine *engine, const char *url);
char *adb_hidden_selectors(const AdbEngine *engine, const char *classes, const char *ids, const char *exceptions);
char *adb_content_blocking(const char *lists);
