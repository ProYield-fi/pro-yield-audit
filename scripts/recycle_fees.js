
// Fee recycling executor: splits USDC sitting in the FeeDistributor per policy
// (depositor boost -> vault.creditYield, treasury, insurance) and records the
// result. Policy file defaults to /home/user/yield_scout/data/recycle_policy.json
// (override with RECYCLE_POLICY; ledger with RECYCLE_LEDGER — the battery's
// journey suite points both at scratch files so it runs on any host).
//
// Usage:  npx hardhat run scripts/recycle_fees.js --network hyperTestnet
//         (add --no-apply via env DRY_RUN=1 for a dry run)
const hre = require("hardhat");
const fs = require("fs");
const path = require("path");

const POLICY_PATH = process.env.RECYCLE_POLICY || "/home/user/yield_scout/data/recycle_policy.json";
const LEDGER_PATH = process.env.RECYCLE_LEDGER || "/home/user/yield_scout/data/recycling.jsonl";

async function main() {
  // Implicit-RPC refusal FIRST: hardhat falls back to http://localhost:8545 when
  // HYPEREVM_RPC_URL is unset, so an unconfigured environment silently recycles
  // against a LOCAL chain that merely spoofs chain-id 998 — that exact trap sent
  // every recycling run (and the insurance slice) to a dev chain on 2026-09-20.
  // Real runs must name their chain; throwaway local runs pass ALLOW_IMPLICIT_RPC=1.
  if (!process.env.HYPEREVM_RPC_URL && process.env.ALLOW_IMPLICIT_RPC !== "1") {
    console.error("REFUSING: HYPEREVM_RPC_URL is not set — hardhat would silently use http://localhost:8545.");
    console.error("Set HYPEREVM_RPC_URL to the intended chain (HyperEVM testnet: https://rpc.hyperliquid-testnet.xyz/evm) or ALLOW_IMPLICIT_RPC=1 for local-only runs.");
    process.exit(3);
  }
  // Chain guard — before any file read or contract binding. The recycler
  // moves real USDC; nothing may run off HyperEVM testnet (998), ever.
  const __net = await hre.ethers.provider.getNetwork();
  if (Number(__net.chainId) !== 998) {
    console.error(`REFUSING: chain ${__net.chainId} is not HyperEVM testnet (998) — never mainnet.`);
    process.exit(3);
  }
  const { HardhatEthersSigner } = require("@nomicfoundation/hardhat-ethers/signers");
  const origSend = HardhatEthersSigner.prototype.sendTransaction;
  HardhatEthersSigner.prototype.sendTransaction = async function (tx) {
    if (tx.gasLimit == null) {
      try {
        const est = await hre.ethers.provider.estimateGas({ ...tx, from: this.address });
        tx = { ...tx, gasLimit: est + 21000n };
      } catch {
        tx = { ...tx, gasLimit: 1_000_000n };
      }
    }
    return origSend.call(this, tx);
  };

  const deployed = JSON.parse(fs.readFileSync(process.env.DEPLOY_MANIFEST || process.env.DEPLOY_MANIFEST || path.join(__dirname, "..", "deployed_addresses.json"), "utf8"));
  const policy = JSON.parse(fs.readFileSync(POLICY_PATH, "utf8"));
  const [owner] = await hre.ethers.getSigners();

  const usdc = await hre.ethers.getContractAt("MockUSDC", deployed.mock_usdc);
  const fd = await hre.ethers.getContractAt("FeeDistributor", deployed.fee_distributor);
  const vault = await hre.ethers.getContractAt("ProYieldVault", deployed.pro_yield_vault);

  // Fail closed if the manifest names contracts that aren't on THIS chain (stale
  // manifest, or a chain-id collision like the local anvil). No code = no move.
  const fdCode = await hre.ethers.provider.getCode(deployed.fee_distributor);
  if (fdCode === "0x") {
    console.error(`REFUSING: no FeeDistributor code at ${deployed.fee_distributor} on chain ${Number(__net.chainId)} — wrong chain or stale manifest.`);
    process.exit(3);
  }

  const dryRun = process.env.DRY_RUN === "1";

  // 1) reconcile FD accounting, then read the recyclable balance
  if (!dryRun) {
    await (await fd.receiveFees()).wait();
  }
  // 1) validate policy FIRST — a bad policy must fail before anything moves
  const boostPct = BigInt(policy.depositor_boost_pct ?? 60);
  const treasuryPct = BigInt(policy.treasury_pct ?? 20);
  const insurancePct = BigInt(policy.insurance_pct ?? 20);
  const total = boostPct + treasuryPct + insurancePct;
  if (total !== 100n) throw new Error(`policy pcts sum to ${total}, must be 100`);

  const bal = await usdc.balanceOf(await fd.getAddress());
  const minAmt = hre.ethers.parseUnits(String(policy.min_amount_usdc ?? 10), 18);
  console.log("FD balance:", hre.ethers.formatUnits(bal, 18), "USDC | min:", hre.ethers.formatUnits(minAmt, 18));
  if (bal < minAmt) {
    console.log("below policy minimum — nothing to recycle");
    return;
  }

  // 2) split per policy

  const boost = (bal * boostPct) / 100n;
  const treasury = (bal * treasuryPct) / 100n;
  const insurance = bal - boost - treasury; // remainder keeps integer exactness

  const treasuryAddr = policy.treasury || owner.address;
  const insuranceAddr = policy.insurance || owner.address;
  console.log(`split: boost=${hre.ethers.formatUnits(boost, 18)} -> depositors | treasury=${hre.ethers.formatUnits(treasury, 18)} -> ${treasuryAddr} | insurance=${hre.ethers.formatUnits(insurance, 18)} -> ${insuranceAddr}`);

  if (dryRun) {
    console.log("DRY RUN — no transactions sent");
    return;
  }

  // 3) execute: route all three parts; credit the boost to depositors
  const ts = Math.floor(Date.now() / 1000);
  const txs = {}; // every value movement is recorded by hash — a ledger line
                  // must be traceable to the chain it claims (was amounts-only)
  if (boost > 0n) {
    txs.route_boost = (await (await fd.route(await vault.getAddress(), boost)).wait()).hash;
    const taPre = await vault.totalAssets();
    // retry-once: if the credit tx fails after routing, the boost sits in the
    // vault as uncredited balance (recoverable — creditYield is balance-guarded
    // and can be re-called by owner). Retry before surfacing the error.
    for (let attempt = 0; ; attempt++) {
      try {
        txs.credit_boost = (await (await vault.creditYield(boost)).wait()).hash;
        break;
      } catch (e) {
        if (attempt >= 1) {
          console.error("CREDIT FAILED — boost is routed and recoverable via vault.creditYield(" + hre.ethers.formatUnits(boost, 18) + "); aborting ledger write");
          throw e;
        }
      }
    }
    const taPost = await vault.totalAssets();
    if (taPost - taPre !== boost) throw new Error("credit did not raise totalAssets exactly");
    console.log("credited boost to depositors:", hre.ethers.formatUnits(boost, 18), "USDC");
  }
  if (treasury > 0n) txs.route_treasury = (await (await fd.route(treasuryAddr, treasury)).wait()).hash;
  if (insurance > 0n) txs.route_insurance = (await (await fd.route(insuranceAddr, insurance)).wait()).hash;

  const remainder = await usdc.balanceOf(await fd.getAddress());
  console.log("FD remainder after recycle:", hre.ethers.formatUnits(remainder, 18), "USDC (rounding dust only)");

  // 4) ledger — main mode only; cold-start runs (DEPLOY_MANIFEST set) must not
  // append main-chain entries (they once polluted the dashboard totals).
  const entry = {
    ts, iso: new Date(ts * 1000).toISOString(),
    source: process.env.RECYCLE_SOURCE || "fees",
    vault: await vault.getAddress(),
    // Where each slice went, and the tx that moved it — traceable on-chain.
    recipients: {
      boost: await vault.getAddress(),
      treasury: treasuryAddr,
      insurance: insuranceAddr,
    },
    txs,
    total: hre.ethers.formatUnits(bal, 18),
    boost: hre.ethers.formatUnits(boost, 18),
    treasury: hre.ethers.formatUnits(treasury, 18),
    insurance: hre.ethers.formatUnits(insurance, 18),
    remainder: hre.ethers.formatUnits(remainder, 18),
  };
  if (process.env.DEPLOY_MANIFEST) {
    console.log("cold-start mode: ledger append skipped");
  } else {
    fs.appendFileSync(LEDGER_PATH, JSON.stringify(entry) + "\n");
    console.log("ledger appended ->", LEDGER_PATH);
  }
  console.log("RECYCLE DONE:", JSON.stringify(entry));
}
main().catch(e => { console.error(e); process.exit(1); });
