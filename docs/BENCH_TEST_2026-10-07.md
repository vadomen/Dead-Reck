# Bench test — Vgate iCar Pro BLE 4.0 on the test car

Parked, ignition on (engine off for the first block, idling for the second). Commands typed in the Car Scanner terminal; Car Scanner had already initialised the adapter (echo off, spaces off). Transcripts are verbatim and are the reference fixtures for the ELM327 parser tests. The VIN is deliberately not recorded here.

## Identity

- BLE name: `IOS-Vlink`
- `ATI` → `ELM327 v2.3`
- `ATDPN` → `6` (ISO 15765-4 CAN, 11-bit, 500 kbaud)
- Responding ECUs to functional requests: `7E8` (engine, "ECM-EngineControl") and `7E9` (most likely the gearbox)

## Block 1 — functional addressing (default), engine off

```
ATI
ELM327 v2.3
>
ATRV
11.0V
>
ATDPN
6
>
ATH1
OK
>
0100
7E906410098180001
7E8064100BE1CA813
>
010D
7E903410D00
7E803410D00
>
010D1
7E903410D00
>
010D0C
7E906410D000C0000
7E806410D000C0000
>
22F40D
NO DATA
>
```

## Block 2 — physical addressing to the engine ECU, engine idling

```
ATSH7E0
OK
>
010D1
7E803410D00
>
010D0C1
7E806410D000C0A5C
>
ATRV
11.8V
>
```

## Decoded

| Reply | Meaning |
|---|---|
| `7E8 06 41 00 BE 1C A8 13` | engine supports PIDs 01, 03–07, 0C, 0D, 0E, 11, 13, 15, 1C, 1F, 20 |
| `7E9 06 41 00 98 18 00 01` | second ECU supports 01, 04, 05, 0C, 0D, 20 |
| `7E8 03 41 0D 00` | speed 0 km/h |
| `7E8 06 41 0D 00 0C 0A 5C` | speed 0 km/h, RPM (0x0A·256 + 0x5C)/4 = 663 |
| `010D1` without `ATSH7E0` → `7E9` only | the suffix returns the first reply, which may come from the wrong ECU |
| `22F40D` → `NO DATA` | OBDonUDS not supported / not needed |

## Conclusions for v1

1. Init must end with `ATSH7E0`; poll with `010D0C1`.
2. The parser must handle two ECUs on one functional request and pick `7E8`.
3. `ATRV` read 11.0 V (engine off) and 11.8 V (idling) — low; cheap clones under-read. Cross-check with `0142` (ECU module voltage) before trusting it. Record `ATRV` but do not alarm on it.
4. Not yet measured: achieved poll rate (Hz) of `010D0C1`, `ATAT1` vs `ATAT2`, behaviour while driving.
