Vendored, unmodified, so `mayhem/build.sh` needs no network (air-gapped, re-runnable builds):

- `libprotobuf-mutator/` — https://github.com/google/libprotobuf-mutator @ a0448e5055e4740774e00d496f016d9fcd572200 (`src/`, `src/libfuzzer/`, `port/`, library sources only)
- `asn1-pdu/` — https://github.com/google/fuzzing `proto/asn1-pdu/` @ 734e55f3cfed1adbb51bf6cb5c65b4c1197b7089 (the ASN.1 PDU proto + DER converter used by the OSS-Fuzz `fuzz_certs`/`fuzz_pkcs12`/`fuzz_pkcs8` harnesses)
