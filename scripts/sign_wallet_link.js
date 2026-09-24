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

const msg = (process.env.MESSAGE || fs.readFileSync(0, "utf8")).trim();
if (!msg.includes("ProYield — wallet link")) {
  console.error("Refusing: not a ProYield wallet-link message.");
  process.exit(1);
}
const key = JSON.parse(
  fs.readFileSync(path.join(os.homedir(), ".proyield", "onramp_usertest.json"), "utf8")
).private_key;
const wallet = new ethers.Wallet(key);
const sig = wallet.signMessage(msg);
// quick self-check: recovered address must equal the signer
if (ethers.verifyMessage(msg, sig).toLowerCase() !== wallet.address.toLowerCase()) {
  console.error("Self-check failed; not printing signature.");
  process.exit(1);
}
console.log(sig);
