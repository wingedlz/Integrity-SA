# Validation — raw_transport_no_sram

검증일: 2026-09-11. 현재 revision은 raw INT8 transport checker와 SRAM tag 회로가 없는 SA core다. 이전 revision 결과가 있는 build/*.log 및 build/synth/는 아래 결과에 포함하지 않는다.

## Verilog-2001 regression — PASS

- Icarus Verilog 12.0 (devel), s20150603-1539-g2693dd32b.
- `iverilog -g2001 -Wall`: 네 RTL과 세 TB를 순수 Verilog 모드로 컴파일했다.
- Compile log에는 diagnostic이 없었다.
- `scripts/run_tests.ps1`의 최종 결과: `ALL_REQUESTED_TESTS_PASS`.
- GEMM seed: `32'h71815ace` (deterministic xorshift).
- 현재 log: `build/raw_transport_no_sram/`.

| K | 정상 GEMM | Golden output 비교 | Compute stalls | Drain stalls |
|---|---:|---:|---:|---:|
| 32 | 143 | 146,432 | 4,875 | 700 |
| 1 | 8 | 8,192 | 175 | 32 |
| 7 | 8 | 8,192 | 182 | 43 |
| 31 | 8 | 8,192 | 278 | 46 |
| **Total** | **167** | **171,008** | **5,510** | **821** |

K=32의 143개는 초기 정상 GEMM 128개, directed case 후 원래 입력을 재제출한 정상 tile 14개, reset 후 정상 tile 1개다. Stall count는 fault tile도 포함한 해당 regression 전체에서 센 값이다.

Golden model은 residue checker나 PE 회로를 재사용하지 않고 signed integer 행렬 곱을 직접 계산한다. 모든 출력 값과 순서, 실제 출력의 arithmetic residue, backpressure 중 출력 유지, done/commit/replay pulse, tile clear, reset abort를 확인했다.

```text
PASS: tb_integrity_sa K=32 clean_gemms=143 checked_values=146432 detected_fault_cases=12 expected_aliases=1 unprotected_input_cases=1 compute_stalls=4875 drain_stalls=700
```

## Unit tests — PASS

`tb_residue`: 총 34,374 checks. Signed INT8 256개 전수 검사, signed INT32 10,104개 directed/random 값, reducer 입력 공간 전수 검사, canonical residue MAC 3,718개 조합, signed 32-step PE tile 100개와 제어 동작을 확인했다.

`tb_stream_checker`: 정상 ingress/egress 시간차 및 stall 20개 frame, raw INT8의 8개 bit 위치 각각의 flip, 동일 residue인 1→106 변경, plain XOR가 상쇄되는 두 MSB 오류의 rotation 검출, 선택한 순서 변경, token 누락·추가·zero token, 65개 token 포화 count, TOKENS=1/7/32를 확인했다.

## Directed injection — 12 detected cases

아래는 고정한 위치와 시점의 directed cases이며 전체 fault coverage 비율은 아니다. 모든 검출 case에서 tile_commit=0, replay_request=1을 확인했다.

| Mode | Injection | 바뀐 main 출력 수 | 검출 flags |
|---|---|---:|---|
| 1 | PE(3,5)의 A forwarding bit 7 | 26 | Transport, arithmetic |
| 2 | PE(3,5)의 A forwarding bit 0 | 26 | Transport, arithmetic |
| 3 | PE(4,7)의 product를 활성 1 cycle 동안 0으로 강제 | 1 | Arithmetic |
| 4 | PE(2,10)의 main accumulator bit 0 | 1 | Arithmetic |
| 5 | PE(6,12)의 mod-7 accumulator bit 0 | 0 | Arithmetic |
| 6 | PE(3,5)의 A forwarding valid 제거 | 26 | Transport, protocol |
| 7 | PE(3,5)의 A forwarding 1→106 | 26 | Transport only |
| 9 | 첫 boundary A valid 제거 | 32 | Transport, protocol |
| 10 | Drain beat 8의 east accumulator bit 0 | 1 | Arithmetic |
| 11 | PE(3,5)의 A mod-7 sideband bit 0 | 0 | Transport, arithmetic |
| 12 | 마지막 drain beat 31의 east accumulator bit 0 | 1 | Arithmetic |
| 14 | PE(5,3)의 B forwarding 1→106 | 26 | Transport only |

Mode 7/14에서는 실제 출력 26개가 달라졌지만 +105 차이여서 mod-7/mod-15, egress sideband 검사, arithmetic 비교가 모두 일치했다. **해당 A/B raw stream checker 자체의 error가 1인지 별도로 확인**하여, raw fingerprint가 이 오류를 검출했음을 확인했다. Mode 1도 raw A stream checker가 최상위 비트 오류를 검출했는지 확인했다.

## Explicitly tested limits — not successful detections

- **Mode 8: main accumulator +105.** 출력 하나가 틀렸지만 arithmetic residues가 같고 transport 데이터는 정상이다. 오류를 발견하지 못해 commit한다. `EXPECTED_ALIAS`로 별도 기록했다.
- **Mode 13: SA ingress 데이터 변경.** 입력을 수락하기 전에 첫 A를 1→0으로 바꿨다. Main 출력 32개가 원래 stimulus의 golden 값과 달라지지만, core는 변경된 입력을 일관되게 계산한다. SRAM tag나 upstream reference가 없으므로 commit한다. `EXPECTED_UNPROTECTED_INPUT`으로 별도 기록했다.

두 사례는 정상 GEMM 167개나 검출 12개에 포함하지 않았다. Replay_request는 0이며, 이후의 정상 계산은 TB가 원래 입력을 명시적으로 다시 제출한 결과다. Hardware가 미검출 오류를 자동 복구한 것이 아니다.

## Scope

Operand buffer, SRAM macro, SRAM tag generation/check, DMA, 자동 reload/recompute controller는 없다. PE의 arithmetic residue forwarding과 edge residue 비교는 메모리 tag 검사가 아니다. RTL에는 injection port, force, delay, file I/O가 없고 fault injection은 TB에만 있다.

Gate-level exhaustive fault campaign, 물리적 radiation SER, ISO 26262 coverage/FIT, ASIC PPA, post-layout timing은 검증하지 않았다. 상위 입력 무결성을 판단할 수 있다는 주장도 하지 않는다.

## FPGA synthesis and structure — PASS; target-device fit — FAIL

수정된 네 RTL의 SHA256을 보존한 임시 복사본으로 Vivado 2023.2 전체 합성을 완료했다. `read_verilog`에 `-sv`를 사용하지 않았고, top은 `integrity_sa_32x32`, K_DEPTH=32, out-of-context mode, part는 `xc7a200tfbg484-2`다.

Synthesis engine은 0 errors / 0 critical warnings / 0 warnings로 완료됐다. DCP와 utilization/timing/DRC 보고서를 생성했고 latch 및 unresolved blackbox 검사도 통과했다. Vivado 시작 시 Tcl store/설정 파일 접근 경고와 후처리 timing/DRC 경고는 log에 남아 있다. 전체 log가 warning-free라는 뜻은 아니다.

| Resource / check | 현재 revision |
|---|---:|
| Slice LUTs, report_utilization 기준 | 175,117 |
| Flip-flops | 78,677 |
| CARRY4 | 24,916 |
| DSP / Block RAM | 각각 0 |
| Mapped latches / unresolved blackboxes | 각각 0 |
| Mod-7 shadow accumulator FF | 3,072 = 1,024×3 |
| Mod-15 shadow accumulator FF | 4,096 = 1,024×4 |

모든 PE에 3+4-bit shadow accumulator가 남았으며 전체 FF 수는 RTL state accounting과 일치한다. 이는 합성 후 논리 state 보존 확인이지 physical fault independence의 증명은 아니다.

사용 LUT는 Artix-7 200T의 134,600개 대비 **130.10%**다. 따라서 해당 FPGA에 들어가는 구현은 아니다. DRC에는 LUT-as-Logic/Slice LUT 과용량 UTLZ-1 오류 2개와 CFGBVS/CONFIG_VOLTAGE 미지정 경고 1개가 있다. Resource DRC를 무시하거나 경고로 낮추는 설정은 사용하지 않았다.

임의 10 ns clock을 합성 후 설정한 timing report의 WNS는 +0.145 ns다. 그러나 input delay 580개, output delay 1,302개와 clock placement가 미지정이고 placement/routing도 수행하지 않았으므로 100 MHz 달성을 주장할 수 없다.

`run_synth.ps1`의 최종 결과:

```text
SYNTHESIS_AND_STRUCTURE_PASS; FPGA_DRC_NOT_CLEAN (see drc.rpt)
```

현재 보고서는 `build/raw_transport_no_sram/synth/`에 있다. `rtl_hashes.json`은 합성에 사용한 source hash, `run_metadata.json`은 실행 경로와 revision을 기록한다. `synthesis_status.txt`의 PASS는 합성과 latch/blackbox 검사 범위에 한정된다. DCP는 build에 보존하며 전달 ZIP에는 작은 보고서와 log만 포함한다.

이전 revision의 175,234 LUT / 78,550 FF와 비교하면 현재 LUT는 117개 적고 FF는 127개 많다. 이는 SRAM tag 비교 회로 제거와 raw XOR 폭 증가를 함께 반영한 **FPGA 매핑 결과**다. ASIC DMR baseline을 합성하지 않았으므로 DMR 대비 ASIC PPA 절감률로 해석하면 안 된다.
