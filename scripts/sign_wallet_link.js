#!/usr/bin/env node
// Sign a ProYield wallet-link challenge with the box-held test wallet key.
// The signature proves control of 0x8377… to the website (no MetaMask needed).
//
// Usage: MESSAGE="$(cat msg.txt)" node scripts/sign_wallet_link.js
//    or: node scripts/sign_wallet_link.js < msg.txt
// Prints ONLY the signature.
const fs = require("fs");
const os = require("os");
const path = require("path");
const { ethers } = require("ethers");

function readStdin() {
  return new Promise((resolve, reject) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => (data += c));
    process.stdin.on("end", () => resolve(data));
    process.stdin.on("error", reject);
  });
}

async function main() {
  const msg = (process.env.MESSAGE || (await readStdin())).trim();
  if (!msg.includes("ProYield — wallet link")) {
    console.error("Refusing: not a ProYield wallet-link message.");
    process.exit(1);
  }
  const key = JSON.parse(
    fs.readFileSync(path.join(os.homedir(), ".proyield", "onramp_usertest.json"), "utf8")
  ).private_key;
  const wallet = new ethers.Wallet(key);
  const sig = await wallet.signMessage(msg); // async in ethers v6
  // quick self-check: recovered address must equal the signer
  if (ethers.verifyMessage(msg, sig).toLowerCase() !== wallet.address.toLowerCase()) {
    console.error("Self-check failed; not printing signature.");
    process.exit(1);
  }
  console.log(sig);
}

main().catch((e) => {
  console.error("sign_wallet_link error:", e.message || e);
  process.exit(1);
});
