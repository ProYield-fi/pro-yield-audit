#!/usr/bin/env node
// scripts/hl_mainnet_deposit.js — deposit USDC from the test wallet to Hyperliquid
// MAINNET via Bridge2 on Arbitrum (the single canonical inbound rail).
//
// Rail facts (verified on-chain 2026-09-23): Bridge2 0x2Df1c51E… on Arbitrum One,
// 19,395 bytes of code, holds ~587M USDC. Native Arbitrum USDC → Bridge2 credits
// the SENDER's HyperCore account. Min deposit 5 USDC. Arbitrum gas (ETH) required
// — refuses without it.
//
// Guards: chainId == 42161, wallet == the expected test wallet (override with
// WALLET_ADDR=… if intentional), amount >= 5. Prints no key material.
//
// Run: node scripts/hl_mainnet_deposit.js            # full balance
//      AMOUNT=12 node scripts/hl_mainnet_deposit.js  # explicit amount
const fs = require("fs");
const os = require("os");
const path = require("path");
const { ethers } = require("ethers");

const ARB_RPC = "https://arb1.arbitrum.io/rpc";
const CHAIN_ID = 42161;
const USDC = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"; // native USDC on Arbitrum
const BRIDGE2 = "0x2Df1c51E09aECF9cacB7bc98cB1742757f163dF7"; // HL Bridge2 — canonical
const WALLET_FILE = path.join(os.homedir(), ".proyield", "onramp_usertest.json");
const HL_API = "https://api.hyperliquid.xyz/info";

const ERC20 = [
  "function balanceOf(address) view returns (uint256)",
  "function transfer(address,uint256) returns (bool)",
  "function decimals() view returns (uint8)",
];

async function hlCredit(address) {
  const res = await fetch(HL_API, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type: "clearinghouseState", user: address }),
  });
  const d = await res.json();
  return d.marginSummary ? d.marginSummary.accountValue : null;
}

async function main() {
  const provider = new ethers.JsonRpcProvider(ARB_RPC);
  const net = await provider.getNetwork();
  if (Number(net.chainId) !== CHAIN_ID) throw new Error(`REFUSING: chain ${net.chainId} != Arbitrum (${CHAIN_ID})`);

  const w = JSON.parse(fs.readFileSync(WALLET_FILE, "utf8"));
  const signer = new ethers.Wallet(w.private_key, provider);
  const expect = process.env.WALLET_ADDR || w.address;
  if (signer.address !== ethers.getAddress(expect)) throw new Error("REFUSING: key file address mismatch");
  console.log("wallet:", signer.address);

  const usdc = new ethers.Contract(USDC, ERC20, signer);
  const bal = await usdc.balanceOf(signer.address);
  console.log("USDC balance:", ethers.formatUnits(bal, 6));
  const eth = await provider.getBalance(signer.address);
  console.log("ETH (gas):", ethers.formatEther(eth));
  if (eth === 0n) throw new Error("REFUSING: no ETH on Arbitrum for gas — buy a little ETH first");

  const amount = process.env.AMOUNT ? ethers.parseUnits(process.env.AMOUNT, 6) : bal;
  if (amount < ethers.parseUnits("5", 6)) throw new Error("REFUSING: HL min deposit is 5 USDC");
  if (amount > bal) throw new Error("REFUSING: amount > balance");

  console.log("sending", ethers.formatUnits(amount, 6), "USDC ->", BRIDGE2, "(HL Bridge2)");
  const gasLimit = ((await usdc.transfer.estimateGas(BRIDGE2, amount)) * 125n) / 100n; // explicit margin (http networks ignore gasMultiplier)
  const tx = await usdc.transfer(BRIDGE2, amount, { gasLimit });
  console.log("tx:", tx.hash);
  await tx.wait();
  console.log("confirmed ✓ | USDC now:", ethers.formatUnits(await usdc.balanceOf(signer.address), 6));

  console.log("polling for the HL credit (bridge processing is not instant)...");
  for (let i = 1; i <= 16; i++) {
    const credit = await hlCredit(signer.address);
    console.log(`  [${i}] HyperCore accountValue: ${credit}`);
    if (Number(credit) >= Number(ethers.formatUnits(amount, 6)) - 0.01) {
      console.log("CREDITED ✓");
      return;
    }
    await new Promise((r) => setTimeout(r, 30000));
  }
  console.log("not credited yet after ~8 min — bridge can lag; re-check clearinghouseState later.");
}

main().catch((e) => {
  console.error("hl_mainnet_deposit error:", e.message || e);
  process.exit(1);
});
