# Cortex — AI agent điều khiển Uniswap v4 hook, launch qua Programmable trên Ethereum

> Tên "Cortex" chỉ là codename. Tên token, ticker, logo, website, X là do bạn cung cấp lúc build — script không tự bịa metadata.

## Narrative

Ba narrative đang chạy cùng lúc, Cortex gom cả ba vào một coin:

1. **AI agent onchain**: agent không chỉ đăng tweet. Nó là "người điều hành" thật của pool: mỗi 20 phút đọc dữ liệu onchain, hỏi Claude, rồi đặt phí giao dịch và quyết định buyback.
2. **Uniswap v4 hooks**: phí và luật chơi nằm trong hook, không nằm trên website.
3. **Proof-of-reasoning + "agent không thể rug"**: mọi quyết định của AI được hash (keccak256) và ghi onchain kèm URI tới file lý giải. Agent chỉ xoay được một núm vặn trong giới hạn cứng không đổi được. Treasury chỉ có một đường tiêu tiền: mua lại và đốt token.

Thêm vào đó là fair launch: 100% supply nằm trong LP single-sided bị khoá vĩnh viễn, không có ví team, không cần ETH để mở pool.

## Kiến trúc

```
                ┌──────────── Programmable Launch Router (Ethereum, V3.3) ─────────────┐
                │  GraphFactory deploy CREATE2 cả graph trong 1 tx do launch wallet ký │
                └──────────────────────────────────────────────────────────────────────┘
 CortexToken ──mint 100%──► CortexLauncher.initialize()
                              ├─ hook.registerPool() → PoolManager.initialize (ETH/TOKEN, LP fee 0.3%)
                              ├─ toàn bộ supply → LP single-sided [minTick, startTick], không có hàm rút
                              └─ initial buy tuỳ chọn (msg.value) → token về launch wallet
 CortexHook (beforeInitialize, before/afterSwap, before/afterSwapReturnDelta = mask 0x20cc)
   ├─ 0.30% platform fee trên ETH gross → 0xD88539d3c4C460136a733A3Fd60cf6BF269079da (yêu cầu của Programmable)
   ├─ 1.00% creator fee cố định → launch wallet (gắn lúc launch, không có hàm đổi)
   ├─ treasury fee do AI agent đặt: 0%–3%, mỗi lần đổi ≤ 0.5%, cách nhau ≥ 15 phút, hết hạn ≤ 24h → về 0.7%
   ├─ không có phí mở cửa / chống bot: mọi người cùng một biểu phí từ block đầu tiên
   └─ distribute(): ai cũng gọi được, người nhận cố định
 CortexTreasury: chỉ buyback-and-burn, chỉ agent (hoặc admin khi không có agent) được gọi, tối đa 20% số dư/lần,
   cooldown 1h, bắt buộc minTokensOut > 0, trượt giá tối đa ~2%, không owner, không withdraw

 agent/ (Node 24 + Claude Opus 5.5 + viem)
   snapshot onchain → Claude (structured output) → guardrails mirror → publish reasoning (hash) → tx
```

### Phí trên mỗi giao dịch

| Thành phần | Mức | Tính trên | Đi đâu |
|---|---|---|---|
| Platform (Programmable) | 0.30% cố định | ETH gross (vào khi mua, ra khi bán), làm tròn lên | `0xD885…79da` |
| Creator | 1% cố định | như trên | Launch wallet (creator) |
| Treasury (AI) | 0%–3%, mặc định 0.70% | như trên | Treasury → buyback & burn |
| LP fee của pool | 0.30% | input của swap | LP bị khoá → `collectLpFees()` → Treasury |

Ví dụ ở chế độ mặc định, một lệnh mua 1 ETH tốn 0.003 ETH platform + 0.01 ETH creator + 0.007 ETH treasury + 0.3% LP fee = 2.3%. Tối đa toàn phần: 4.6%/lệnh (cộng 0.3% router fee nếu giao dịch qua Programmable). Request khai báo phần project tối đa 4% (creator 1% + treasury 3%).

### Quyền kiểm soát (cần công khai khi review)

- `hook.admin` (= launch wallet): chỉ đổi hoặc thu hồi agent key, chuyển hoặc từ bỏ admin. Không đổi được phí, cap, người nhận.
- `hook.agent`: chỉ `setAgentFee` trong guardrail và gọi `buyback`. Thu hồi agent thì phí về 0.7% và quyền buyback chuyển cho admin; nếu cả hai bị từ bỏ thì buyback dừng hẳn (không bao giờ public).
- Không có mint, pause, blacklist, proxy, upgrade, selfdestruct hay hàm rút tiền trong bất kỳ contract nào.

## Cấu trúc thư mục

```
cortex-hook/
  contracts/
    src/CortexToken.sol  CortexHook.sol  CortexLauncher.sol  CortexTreasury.sol
    test/Cortex.t.sol            Foundry tests (fee basis, guardrails, buyback, LP fees)
    build-and-configure.mjs      compile solc 0.8.26 + sinh programmable-launch.config.json
    foundry.toml  .env.example
  agent/
    src/index.ts   vòng lặp      src/market.ts      snapshot onchain
    src/brain.ts   Claude        src/guardrails.ts  mirror luật onchain
    src/executor.ts simulate → gửi tx, ghi reasoning/<hash>.json
```

## Launch trên Ethereum Mainnet: từng bước

Theo đúng docs của Programmable: Custom Launch API **V3.3**, CLI `@programmable/launch` **3.3.9**, profile `3.3.0`, chain `1`.

### 0. Chuẩn bị

- Node.js ≥ 24.14, [Foundry](https://book.getfoundry.sh/), một repo GitHub **public** để chứa source.
- API key tạo tại https://programmable.market/developers/api-keys với scope `custom-launch:create` + `custom-launch:read`, gắn với launch wallet. Lưu vào biến môi trường `PROGRAMMABLE_API_KEY`, không ghi vào file, không dán vào chat.
- Hai ví: **launch wallet** (ký launch, là admin) và **agent hot wallet** (chỉ chứa ít ETH trả gas).

### 1. Cài CLI chính thức (chỉ từ GitHub Release, có checksum)

```bash
curl --fail --location -o programmable-launch-3.3.9.tgz https://github.com/programmablehq/PROGRAMMABLE/releases/download/programmable-launch-v3.3.9/programmable-launch-3.3.9.tgz
```
```bash
curl --fail --location -o programmable-launch-3.3.9.tgz.sha256 https://github.com/programmablehq/PROGRAMMABLE/releases/download/programmable-launch-v3.3.9/programmable-launch-3.3.9.tgz.sha256
```
```bash
shasum -a 256 -c programmable-launch-3.3.9.tgz.sha256
```
```bash
npm install --global ./programmable-launch-3.3.9.tgz
```

Trên Windows thay `shasum` bằng `Get-FileHash programmable-launch-3.3.9.tgz -Algorithm SHA256` rồi so với nội dung file `.sha256`. Chỉ tiếp tục khi checksum khớp và `programmable-launch --version` in ra `3.3.9`.

### 2. Copy module settlement-fee-vault từ package CLI

```bash
cd contracts && mkdir -p release-modules
```
```bash
cp "$(npm root --global)/@programmable/launch/test/fixtures/programmable-settlement-fee-vault-v1.json" release-modules/
```
```bash
cp "$(npm root --global)/@programmable/launch/test/fixtures/programmable-settlement-fee-vault-v1.standard-json.json" release-modules/
```

`build-and-configure.mjs` kiểm SHA-256 của 2 file này với giá trị Programmable công bố và dừng nếu lệch.

### 3. Cài dependency, chạy test

```bash
npm ci
```
```bash
forge install foundry-rs/forge-std@v1.9.7 --no-git
```

(Nếu máy không có git: tải zip `forge-std` v1.9.7 từ GitHub và giải nén vào `contracts/lib/forge-std`.) Trong test luôn dùng `vm.getBlockNumber()` / `vm.getBlockTimestamp()` thay vì `block.number` / `block.timestamp`, vì `via_ir` cache các giá trị này giữa các lần `vm.roll` / `vm.warp`.
```bash
forge test -vv
```

Lưu output test vào `evidence/forge-test.txt` (build sẽ tự đưa vào `agentAttestation`).

### 4. Push source lên GitHub public, lấy commit

Graph V3 bind source theo `publicOrigin.url` + `revision` (commit 40 ký tự). Commit phải chứa đúng bytes của `src/`, `package-lock.json`, `release-modules/`.

### 5. Điền `.env` và build config

```bash
cp .env.example .env
```
```bash
npm run build
```

Script compile bằng `solc 0.8.26+commit.8a97fa7a` (cancun, viaIR, optimizer 200, không CBOR, đúng cấu hình của ví dụ chính thức), map immutables, rồi ghi `programmable-launch.config.json` với 4 target: `launcher` (initializer), `token`, `hook` (salt do CLI grind để khớp mask `0x20cc`, đồng thời là target ràng buộc phí platform), `treasury`. Profile 3.6.0 không còn bắt buộc vault phí của Programmable. Liquidity model: `launch-seeded-concentrated-liquidity`.

### 6. Pack, validate, submit

```bash
programmable-launch pack --config programmable-launch.config.json --output launch.json
```
```bash
programmable-launch validate launch.json --config programmable-launch.config.json --remote
```
```bash
programmable-launch submit launch.json --config programmable-launch.config.json
```
```bash
programmable-launch status REQUEST_UUID --watch --until authorized
```

**Chạy `pack` ngay sau `npm run build`**: CLI giới hạn `permitWindow` tối đa 1 giờ (Programmable tự làm mới cửa sổ giao dịch sau khi duyệt; contract Cortex không nhúng deadline nào nên không có gì hết hạn trong lúc review).

**Trên Windows**: CLI gọi `fsync` trên thư mục, Windows trả `EPERM`. Để chạy `pack`/`validate` local, nạp shim đi kèm (không sửa CLI):

```bash
node --import ./scripts/win-fsync-shim.mjs "$(npm root --global)/@programmable/launch/bin/programmable-launch.mjs" pack --config programmable-launch.config.json --output launch.json
```

Với `submit` thật, nên chạy CLI trên Linux, macOS hoặc WSL, để journal idempotency được ghi bền vững đúng như CLI thiết kế.

- Đọc kỹ `launchEligibility`, findings, `needsEvidenceFindingCodes`. `action_required` nghĩa là phải sửa source, repack và submit request mới.
- Request vào **manual review** (mục tiêu 24h). Reviewer chạy fork-check buy/sell để xác nhận pool thu đủ 0.3% cho `0xD885…79da`. Có thể trả lời reviewer qua trang launch.
- Khi được duyệt, có **24h** để ký. Mở `walletHandoffUrl`, kiểm tra chain `1`, Router, value (= initial buy nếu có), calldata, rồi ký bằng launch wallet.

```bash
programmable-launch status REQUEST_UUID --watch --until finalized
```

Timeout hoặc lỗi 429/503: chỉ retry với **đúng bytes và idempotency key cũ**, không tạo launch thứ hai.

### 7. Chạy AI agent

```bash
cd ../agent && npm ci && cp .env.example .env
```

Điền `HOOK_ADDRESS` (địa chỉ hook sau khi finalized), `RPC_URL`, `ANTHROPIC_API_KEY`, `AGENT_PRIVATE_KEY` của hot wallet. Chạy thử 1 vòng ở chế độ dry-run:

```bash
npm run once
```

Khi đã hài lòng, đặt `DRY_RUN=false` rồi chạy liên tục:

```bash
npm start
```

Mỗi vòng agent sẽ:
1. dọn phí: `hook.distribute()`, `launcher.collectLpFees()`, `treasury.burnHeldTokens()`;
2. chụp snapshot: giá, market cap, dòng tiền mua/bán 1h và 6h, lệnh lớn nhất, volatility theo tick, quỹ treasury, phí hiện tại, cooldown;
3. hỏi Claude Opus 5.5 (structured output, adaptive thinking, server-side refusal fallback bật sẵn) để chọn regime, treasury fee, TTL, buyback, kèm một bài post công khai;
4. áp guardrail giống hệt onchain (cap, step, rate-limit, cooldown, 20% balance, slippage);
5. ghi `reasoning/<keccak>.json` và `posts/*.txt`, simulate rồi gửi `setAgentFee(fee, ttl, hash, uri)` và/hoặc `buyback(eth, minOut, hash)`.

Host thư mục `agent/reasoning/` công khai (ví dụ trên website ở `/reasoning`) và đặt `REASONING_BASE_URL` để URI onchain mở được. Ai cũng có thể tải file về, hash lại và so với event `AgentRegimeUpdated`.

## Trạng thái kiểm chứng

- `npm run compile`: 4 contract compile sạch với solc 0.8.26 (hook 8.9 KB, launcher 6.3 KB, treasury 3.5 KB, token 1.8 KB).
- `agent`: `tsc --noEmit` sạch; guardrails và canonical JSON đã smoke-test.
- `forge test` (Foundry 1.5.1, forge-std v1.9.7): **15/15 pass**, gồm fuzz 512 lần cho công thức phí exact-output. Output lưu ở `contracts/evidence/forge-test.txt`.
- CLI `@programmable/launch` 3.3.9 (checksum khớp release): `pack` + `validate` offline với metadata giả lập đều **pass** (`reproducedFromConfig: true`, `exactSourceIncluded: true`). CLI grind được salt cho hook với mask `0x20cc`.
- **Chưa chạy**: `validate --remote` / `submit` (cần API key, launch wallet và metadata thật), và agent trên mainnet.
- Contract **chưa audit**. Programmable review chỉ xác nhận provenance và fee, không phải audit.

## Rủi ro và lưu ý

- Swap exact-output khi giá chạm price limit (partial fill) sẽ revert theo thiết kế, để phí luôn tính đúng trên gross.
- LP single-sided nghĩa là pool chỉ có ETH sau khi có người mua. Giá mở do `CORTEX_START_TOKENS_PER_ETH` quyết định.
- Agent key bị lộ thì kẻ tấn công tối đa chỉ đẩy phí lên 3% (theo bước 0.5%/15 phút) và buyback 20%/giờ. Admin thu hồi bằng `setAgent(0x0)`.
- Đây không phải lời khuyên tài chính. Token có thể mất toàn bộ giá trị.
