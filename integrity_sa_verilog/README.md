# Integrity-SA — simple core, raw transport fingerprints

순수 Verilog-2001의 32×32 output-stationary SA다. Signed INT8×INT8/INT32 GEMM, 독립적인 mod-7/mod-15 MAC, raw INT8 기반 XOR/rotation transport checker, east-edge output checking을 구현한다.

외부 데이터와 valid를 수락하는 SA core다. Operand buffer, SRAM 및 SRAM tag generation/check 회로는 포함하지 않는다.

## Files and execution

| File | Role |
|---|---|
| `rtl/integrity_sa_32x32.v` | 1,024 PE, 64개 raw transport checker, edge 비교, tile 제어 |
| `rtl/isa_pe.v` | Main/residue MAC, forwarding, accumulator drain |
| `rtl/isa_residue.v` | Signed INT8/INT32 converter와 folding 회로 |
| `rtl/isa_stream_checker.v` | XOR8, rotation-XOR32, token count, sticky error |
| `tb/tb_integrity_sa.v` | 독립 golden GEMM, stall/backpressure, fault injection |
| `tb/tb_residue.v` | 변환기·reduction·residue MAC·PE 단위검사 |
| `tb/tb_stream_checker.v` | Raw byte 데이터·순서·누락·추가 검사 |
| `scripts/run_tests.ps1` | Verilog-2001 compile, simulation, PASS/FAIL 확인 |
| `scripts/run_synth.ps1` | 임시 복사본 합성, source hash 확인, 보고서 회수 |
| `scripts/synth_check.tcl` | 전체 array FPGA 합성 및 구조 검사 |

이 디렉터리에서 PowerShell로 실행한다. 도구가 PATH에 있으면 경로 인자를 생략할 수 있다.

```powershell
.\scripts\run_tests.ps1 -Iverilog C:/iverilog/bin/iverilog.exe -Vvp C:/iverilog/bin/vvp.exe
.\scripts\run_synth.ps1 -Vivado C:/Xilinx/Vivado/2023.2/bin/vivado.bat
```

테스트벤치는 독립 golden GEMM과의 출력 비교, stall/backpressure, directed fault injection 및 미검출 사례를 검사하도록 구성되어 있다. 실행 결과는 생성된 로그에서 확인한다.

실행 결과는 `build/raw_transport_no_sram/`에 저장한다.

합성 wrapper는 이 호스트의 Vivado/Windows Tcl 정리 오류를 피하려고 고유 임시 디렉터리와 `--keep-temp`를 사용한다. 임시 경로와 source hash를 기록하며 설치 파일은 수정하지 않는다. FPGA 합성과 구조 검사, device-fit/DRC, 배치·배선 결과는 구분한다.

## Arithmetic and input contract

```text
C[r,c] = sum(k=0..K_DEPTH-1) A[r,k] * B[k,c]
acc_next = acc + signed(A) * signed(B)
s7_next  = (s7  + A7  * B7 ) mod 7
s15_next = (s15 + A15 * B15) mod 15
```

- 배열은 고정 32×32이고 K_DEPTH는 합성 parameter 1..32, 기본값 32다.
- Main product는 signed 16-bit, accumulator는 signed 32-bit다.
- Mod-7 MAC은 3×3 multiplier/3-bit state, mod-15 MAC은 4×4 multiplier/4-bit state다.
- Tile마다 accumulator=0으로 시작한다. Bias, 기존 C에 대한 누산, saturation, quantization은 포함하지 않는다.
- 정상 |C|≤32×16384=524288이므로 INT32 overflow가 없다.
- RTL에는 division이나 `%`가 없다. Mersenne folding과 signed 보정을 사용하며, `%`는 독립 golden model을 계산하는 TB에서만 사용한다.

입력 공급 장치를 지정하지 않는다. 외부는 다음 스케줄로 데이터를 공급한다. **TB의 배열은 stimulus/golden 저장용이며 operand buffer의 RTL 모델이 아니다.**

```text
wave_index=t:
  a_west_flat[r*8 +: 8]  = A[r,t-r], valid iff 0 <= t-r < K_DEPTH
  b_north_flat[c*8 +: 8] = B[t-c,c], valid iff 0 <= t-c < K_DEPTH
```

Start는 busy=0인 rising edge에서 수락하며 해당 edge에서는 clear만 수행한다. 이후 input_ready=1인 edge에서 데이터를 소비한다. Step_en=0은 RUN의 wave, 모든 PE와 transport checker를 함께 정지시킨다. 개별 lane stall은 지원하지 않으며 스케줄과 다른 valid는 protocol_error다. Busy 중 start는 무시한다. Reset은 active-low synchronous다.

## Raw transport checking and arithmetic sidebands

Ingress converter에서 각 operand의 residue를 계산해 raw operand 8-bit와 별도의 arithmetic sideband 7-bit로 forwarding한다. A는 east, B는 south로 이동한다. PE의 작은 MAC은 이 sideband를 사용한다.

Transport checker는 modulo 변환을 거치지 않고 **ingress/egress의 실제 raw byte**를 사용한다. A 32행과 B 32열에 독립 checker를 둔다.

```text
x = raw_operand[7:0]
P_next = P XOR x
Q_next = ROTL32(Q,9) XOR zero_extend_32(x)
count_next = saturating_increment(count)
```

P는 8-bit, Q는 32-bit이며 ingress/egress에 각각 유지한다. Accepted token에 대해서만 갱신한다. Rotation은 `{Q[22:0],Q[31:23]}`의 고정 배선이다. L개 token 후 token i의 회전량은 9×(L−1−i)다. A와 B를 하나의 XOR에 섞지 않는다.

한 tile이 한 frame이다. Count는 6-bit로 32에서 포화하며 K_DEPTH보다 많은 token은 즉시 sticky error를 남긴다. 최종 P/Q/count 비교는 VERIFY에서 수행한다. 32 token마다 회전 위치가 반복되므로 frame 길이를 임의로 확장하면 안 된다.

Egress의 INT8 converter는 전달된 **arithmetic sideband가 raw data와 같은지** 비교하는 데 사용한다. 이것은 저장 tag 검사가 아니다. Converter 수는 INT8 pair 128개(ingress 64 + egress 64), INT32 pair 32개(edge)다. Signed 변환은 unsigned residue에서 sign에 따른 2^8/2^32 보정을 하며 보정값은 mod-7=4, mod-15=1이다.

Raw fingerprint는 `1→106`처럼 modulo가 같은 forwarding 오류도 검출한다. 여러 token의 오류 상쇄나 checker/control 공통모드 오류는 미검출될 수 있다. Main accumulator의 +105 alias는 arithmetic check로 검출할 수 없다.

## Output and commit

```text
IDLE -> RUN -> VERIFY -> DRAIN -> REPORT -> IDLE

accepted drain beat  0: C[0..31,31]
accepted drain beat  1: C[0..31,30]
...
accepted drain beat 31: C[0..31, 0]
```

32행이 병렬로 east 방향으로 한 칸씩 이동하므로 32 results/cycle이다. Main accumulator와 두 residue accumulator를 함께 이동시킨다. **동일한 accumulator register를 계산과 drain에 사용하므로 compute와 drain은 순차적으로 수행한다.**

East edge의 32개 converter/비교기가 각 PE의 최종 결과를 검사한다. Out_valid && out_ready에서 결과를 latch하고 shift한다. Out_ready=0이면 data, residue, out_bad, out_col 및 drain index를 유지한다. Out_r7_flat/out_r15_flat은 실제 출력 데이터의 residue를 보여주는 arithmetic 관측 포트다. SRAM tag 생성기나 write protocol은 아니다.

Stall 없는 K=32는 RUN 95 + VERIFY 1 + DRAIN 32 + REPORT 1 = start부터 done까지 **129 clock periods**다. 일반식은 K_DEPTH+97이다. 마지막 drain beat 오류도 REPORT에 반영한다.

Done은 1-cycle pulse이고 같은 cycle에 tile_commit 또는 replay_request 중 하나를 낸다. Tile_commit은 구현된 검사에서 오류를 발견하지 못했다는 뜻이다. 수신 측은 tile_commit 전까지 출력을 speculative하게 취급해야 한다. 내부 출력 buffer나 자동 replay controller는 없다. RUN 중 오류를 먼저 발견해도 drain을 마친 뒤 replay를 요청한다. Reset은 진행 중 tile을 abort하고 완료 pulse를 내지 않는다.

## Top-level interface

| Port | Width | Contract |
|---|---:|---|
| `clk`, `rst_n` | 1 each | Rising-edge clock, synchronous active-low reset |
| `start`, `busy` | 1 each | Idle에서 start 수락 |
| `step_en`, `input_ready` | 1 each | RUN 전체 advance; input_ready=RUN && step_en |
| `wave_index` | 7 | 현재 입력 wave |
| `a_west_flat`, `b_north_flat` | 256 each | Lane i의 INT8은 `[i*8 +: 8]` |
| `a_valid_west`, `b_valid_north` | 32 each | Lane별 스케줄 valid |
| `out_valid`, `out_ready` | 1 each | 32개 결과 동시 handshake |
| `out_col` | 5 | 원래 column, 31→0 |
| `out_data_flat` | 1024 | Row r의 INT32는 `[r*32 +: 32]` |
| `out_r7_flat`, `out_r15_flat` | 96, 128 | 실제 edge data의 arithmetic residues |
| `out_bad` | 32 | Row별 edge mismatch |
| `transport_error` | 1 | Raw P/Q/count 또는 arithmetic sideband mismatch |
| `arithmetic_error` | 1 | 수락된 edge data와 shadow residue mismatch |
| `protocol_error` | 1 | Boundary schedule 또는 PE A/B valid 불일치 |
| `tile_error` | 1 | 위 세 error의 OR |
| `done`, `tile_commit`, `replay_request` | 1 each | 완료 pulse 및 tile 처리 결과 |

Error는 다음 accepted start/reset까지 sticky다. Out_valid=0이면 출력 data/column/residue/out_bad를 소비하지 않는다.

## Protection boundary

기준 입력은 SA boundary에서 수락한 값이다. **수락 이전의 입력 손상은 보호 범위 밖이다.** 첫 A 입력이 1에서 0으로 바뀌면 main/shadow MAC과 transport fingerprint 모두 그 0을 기준으로 동작한다. 이를 검출하려면 별도의 저장 tag 또는 입력 경로 reference가 필요하다.

TB는 ingress 변경을 `EXPECTED_UNPROTECTED_INPUT`, accumulator +105를 `EXPECTED_ALIAS`로 따로 기록한다. 두 경우 모두 hardware는 replay를 요청하지 않는다. 그 뒤 정상 계산은 TB가 원래 입력을 명시적으로 재제출한 시험이다.

## RTL state accounting

| State | Bits |
|---|---:|
| Main accumulators | 32,768 |
| Two residue accumulators | 7,168 |
| Raw A/B forwarding | 16,384 |
| A/B residue forwarding | 14,336 |
| A/B valid forwarding | 2,048 |
| 64 stream checkers: 64×(16+64+12+1) | 5,952 |
| Controller/global flags | 21 |
| **Total** | **78,677** |

전체 area는 register 수만으로 판단할 수 없다. DMR 대비 ASIC 면적·전력 절감률은 동일 조건의 baseline 비교가 필요하다.
