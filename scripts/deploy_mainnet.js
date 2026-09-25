/**
 * Mainnet deploy — HyperEVM (999). DRY BY DEFAULT; sending requires MAINNET_OK=1.
 *
 * Deploys the S2 "team stage" minimal set — idle-capable, no strategies:
 *   FeeDistributor(USDC)                          fee-routing target
 *   ProYieldVault(USDC, owner, feeDistributor)    caps set in the same run
 *
 * Deliberately NOT deployed (attack-surface rule, docs/VAULT_UNLOCK_PLAN.md §7):
 * strategies/adapters (no venue adapter is registered — the vault holds idle
 * USDC for the team E2E money path), the PYD suite, satellites.
 *
 * Guards — every one must pass before a single wei moves:
 *   1. MAINNET_OK=1                       explicit human go-ahead
 *   2. provider chainId == 999            refuse any other chain outright
 *   3. deployer == EXPECTED_DEPLOYER      refuse surprise keys
 *   4. manifest absent (FORCE=1 overrides) refuse silent redeploys
 *   5. USDC code+d 6 decimals+symbol at 0xb88339CB… (Circle-native)
 *
 * Env:
 *   MAINNET_OK=1        required to send (otherwise read-only plan + estimates)
 *   DRY=1               explicit dry run (same as omitting MAINNET_OK)
 *   TVL_CAP             whole USDC, default 500   (S2 team stage)
 *   PER_USER_CAP        whole USDC, default 500   (S2 team stage)
 *   OWNER               default = deployer (transfer to the treasury Safe
 *                       before cohort opens — checklist item)
 *   FORCE=1             overwrite an existing manifest
 *   DEPLOY_MANIFEST     manifest path override (fork runs!)
 *
 *   npx hardhat run scripts/deploy_mainnet.js --network hyperMainnet
 */
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const USDC = "0xb88339CB7199b77E23DB6E890353E22632Ba630f"; // Circle-native, 6dp
const EXPECTED_DEPLOYER = process.env.EXPECTED_DEPLOYER || "0xaDD8f2678De34FD06C158DD80C5253A504A5EA1D";
const MANIFEST = process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.mainnet.json");

const SEND = process.env.MAINNET_OK === "1" && process.env.DRY !== "1";
const FORCE = process.env.FORCE === "1";

function fail(msg) {
  console.error(`REFUSING: ${msg}`);
  process.exit(3);
}

async function main() {
  const { ethers } = hre;

  // ── Guard 2: chain identity ────────────────────────────────────────────────
  const net = await ethers.provider.getNetwork();
  const chainId = Number(net.chainId);
  console.log(`network: ${hre.network.name} · chainId ${chainId} · ${SEND ? "SEND MODE" : "DRY MODE"}`);
  if (chainId !== 999) fail(`chainId ${chainId} is not HyperEVM mainnet (999)`);

  // ── Guard 3: expected deployer ─────────────────────────────────────────────
  const [deployer] = await ethers.getSigners();
  if (deployer.address.toLowerCase() !== EXPECTED_DEPLOYER.toLowerCase()) {
    fail(`deployer ${deployer.address} != expected ops EOA ${EXPECTED_DEPLOYER}`);
  }
  const bal = await ethers.provider.getBalance(deployer.address);
  console.log(`deployer: ${deployer.address} · gas balance ${ethers.formatEther(bal)} HYPE`);

  // ── Guard 5: real USDC exists & looks right ────────────────────────────────
  const code = await ethers.provider.getCode(USDC);
  if (code === "0x") fail(`no code at USDC ${USDC} on chain ${chainId}`);
  const usdc = new ethers.Contract(
    USDC,
    ["function decimals() view returns (uint8)", "function symbol() view returns (string)"],
    ethers.provider
  );
  const [decimals, symbol] = await Promise.all([usdc.decimals(), usdc.symbol()]);
  console.log(`asset: USDC ${USDC} · ${symbol} · ${decimals}dp`);
  if (Number(decimals) !== 6 || symbol !== "USDC") fail(`USDC sanity failed (${symbol}/${decimals})`);

  // ── Guard 4: manifest absent ───────────────────────────────────────────────
  if (fs.existsSync(MANIFEST) && !FORCE) {
    fail(`manifest already exists at ${MANIFEST} — deploy would shadow it. FORCE=1 to override.`);
  }

  // ── Parameters ─────────────────────────────────────────────────────────────
  const owner = process.env.OWNER || deployer.address;
  if (!ethers.isAddress(owner)) fail(`OWNER not an address: ${owner}`);
  const tvlCap = ethers.parseUnits(process.env.TVL_CAP || "500", 6);
  const perUserCap = ethers.parseUnits(process.env.PER_USER_CAP || "500", 6);
  console.log(`owner: ${owner}`);
  console.log(`caps: tvl ${ethers.formatUnits(tvlCap, 6)} USDC · per-user ${ethers.formatUnits(perUserCap, 6)} USDC`);

  const FD = await ethers.getContractFactory("FeeDistributor");
  const VAULT = await ethers.getContractFactory("ProYieldVault");
  const fdArgs = [USDC];
  const vaultArgs = [USDC, owner, "0x0000000000000000000000000000000000000000"]; // FD address patched after deploy

  // ── Gas sizing (always) ────────────────────────────────────────────────────
  // HyperEVM HARD CONSTRAINT: block gas limit is 3,000,000 (verified on mainnet
  // and testnet, 2026-09-24) — a single tx exceeding it is rejected outright
  // ("intrinsic gas too high"). Also, eth_estimateGas for raw CREATE data is
  // unreliable on the public RPC (returned ~161k for an 18KB vault). So: size
  // from bytecode (200 gas/byte runtime + ctor margin), then clamp under the
  // block limit. Unused gas is refunded; over-limit is a hard reject.
  const BLOCK_GAS_CAP = 2990000n;
  const clamp = (x) => (x > BLOCK_GAS_CAP ? BLOCK_GAS_CAP : x);
  // Size from the DEPLOYED (runtime) bytecode — that's what costs 200 gas/byte.
  // (The creation bytecode also carries the ctor, which executes at a fraction
  // of that rate; the +500k/+700k margins cover it comfortably.)
  const fdDeployedBytes = BigInt((require("../artifacts/contracts/FeeDistributor.sol/FeeDistributor.json").deployedBytecode.length - 2) / 2);
  const vaultDeployedBytes = BigInt((require("../artifacts/contracts/ProYieldVault.sol/ProYieldVault.json").deployedBytecode.length - 2) / 2);
  const fdGas = clamp(21000n + 200n * fdDeployedBytes + 500000n);
  const vaultGas = clamp(21000n + 200n * vaultDeployedBytes + 700000n);
  const totalEst = fdGas + vaultGas + 200000n;
  const feeData = await ethers.provider.getFeeData();
  const gasPrice = feeData.maxFeePerGas ?? feeData.gasPrice ?? 1n;
  const cost = totalEst * gasPrice;
  console.log(
    `gas plan: FD ≤${fdGas} + vault ≤${vaultGas} (+caps/calls) → ~${ethers.formatEther(cost)} HYPE at ${gasPrice} wei/gas`
  );
  if (bal < cost) fail(`insufficient gas: have ${ethers.formatEther(bal)} HYPE, need ~${ethers.formatEther(cost)} (sized)`);

  if (!SEND) {
    console.log("\nDRY — nothing sent. Re-run with MAINNET_OK=1 to deploy.");
    console.log(`would deploy: FeeDistributor(${USDC}) + ProYieldVault(${USDC}, ${owner}, <FD>) + setCaps(${tvlCap}, ${perUserCap})`);
    return;
  }

  // ── Deploy ─────────────────────────────────────────────────────────────────
  console.log("\nDeploying FeeDistributor…");
  const fd = await FD.deploy(...fdArgs, { gasLimit: fdGas });
  await fd.waitForDeployment();
  const fdAddr = await fd.getAddress();
  const fdReceipt = await fd.deploymentTransaction().wait();
  console.log(`FeeDistributor: ${fdAddr} (gasUsed ${fdReceipt.gasUsed})`);

  console.log("Deploying ProYieldVault…");
  const vault = await VAULT.deploy(USDC, owner, fdAddr, { gasLimit: vaultGas });
  await vault.waitForDeployment();
  const vaultAddr = await vault.getAddress();
  const vaultReceipt = await vault.deploymentTransaction().wait();
  console.log(`ProYieldVault: ${vaultAddr} (gasUsed ${vaultReceipt.gasUsed})`);

  console.log("Setting caps…");
  let capsGas = 300000n;
  try {
    capsGas = (await vault.setCaps.estimateGas(tvlCap, perUserCap)) + 100000n;
  } catch (_) {
    /* fall back to the flat floor */
  }
  const tx = await vault.setCaps(tvlCap, perUserCap, { gasLimit: capsGas });
  await tx.wait();
  console.log("setCaps done:", tx.hash);

  // ── Read-back verification (before the manifest is written) ────────────────
  const rb = {
    asset: await vault.underlying(), // BaseStrategy exposes the asset as `underlying`
    owner: await vault.owner(),
    fee_distributor: await vault.feeDistributor(),
    tvl_cap: await vault.tvlCap(),
    per_user_cap: await vault.perUserCap(),
    deposits_paused: await vault.depositsPaused(),
    performance_fee: await vault.performanceFee(),
    withdrawal_fee: await vault.withdrawalFee(),
    total_assets: await vault.totalAssets(),
    fd_usdc: await fd.usdc(),
  };
  const checks = [
    ["asset == USDC", rb.asset.toLowerCase() === USDC.toLowerCase()],
    ["owner set", rb.owner.toLowerCase() === owner.toLowerCase()],
    ["feeDistributor wired", rb.fee_distributor.toLowerCase() === fdAddr.toLowerCase()],
    ["tvlCap", rb.tvl_cap === tvlCap],
    ["perUserCap", rb.per_user_cap === perUserCap],
    ["deposits open", rb.deposits_paused === false],
    ["perf fee 1000bps", rb.performance_fee === 1000n],
    ["withdrawal fee 0", rb.withdrawal_fee === 0n],
    ["vault empty", rb.total_assets === 0n],
    ["FD usdc == USDC", rb.fd_usdc.toLowerCase() === USDC.toLowerCase()],
  ];
  let ok = true;
  for (const [name, pass] of checks) {
    console.log(`  ${pass ? "✓" : "✗"} ${name}`);
    ok = ok && pass;
  }
  if (!ok) fail("read-back verification failed — manifest NOT written; investigate before using these addresses");

  // ── Manifest ───────────────────────────────────────────────────────────────
  const manifest = {
    // chain as an OBJECT — the vault-status writer + ecosystem audit read
    // chain.id / chain.name for identity labels (a bare string publishes
    // "chain undefined" and mis-classifies the feed as testnet).
    chain: { id: 999, name: "hyperevm-mainnet", rpc: "https://rpc.hyperliquid.xyz/evm" },
    chain_id: 999,
    deployed_utc: new Date().toISOString(),
    deployer: deployer.address,
    owner,
    vault_asset: USDC,
    fee_distributor: fdAddr,
    pro_yield_vault: vaultAddr,
    caps: {
      tvl_cap_usdc: ethers.formatUnits(tvlCap, 6),
      per_user_cap_usdc: ethers.formatUnits(perUserCap, 6),
    },
    fees: { performance_fee_bps: 1000, withdrawal_fee_bps: 0 },
    stage: "S2-team",
    _notes: [
      "Minimal set — vault + FeeDistributor only; strategies/PYD suite deliberately absent (VAULT_UNLOCK_PLAN §7).",
      "Owner is an EOA at deploy time — transfer to the treasury Safe before cohorts open.",
      "team E2E: deposit → shares → withdraw via scripts/customer_deposit.js / customer_withdraw.js patterns.",
    ],
  };
  fs.writeFileSync(MANIFEST, JSON.stringify(manifest, null, 2));
  console.log(`\n✅ deployed + verified. Manifest: ${MANIFEST}`);
  console.log("NEXT: team E2E deposit/withdraw · ownership transfer to Safe · keeper/alerts config · attestation config flip.");
}

main().catch((e) => {
  console.error("deploy_mainnet failed:", e.message || e);
  process.exit(4);
});
