// Vault caps + pause (S2 beta safety rails) — self-deploying battery suite.
//
// Proves, on a fresh isolated chain:
//   A1  defaults: uncapped (0), unpaused
//   A2  deposit EXACTLY at the TVL cap passes
//   A3  one wei over the TVL cap reverts with the message
//   A4  withdrawals are unaffected by the cap and re-open headroom
//   A5  per-user cap is per-USER (second user fills independently)
//   A6  one wei over the per-user cap reverts with the message
//   A7  pause blocks deposits (message), A8 withdrawals stay open while paused
//   A9  unpause re-opens deposits
//   A10/A11 setters are owner-only
//   A12 zeros restore the uncapped behavior (cap is opt-in, not sticky)
const hre = require("hardhat");

let pass = 0, fail = 0;
function report(name, ok, detail = "") {
  if (ok) { pass++; console.log(`✅ ${name}${detail ? " — " + detail : ""}`); }
  else { fail++; console.log(`❌ ${name}${detail ? " — " + detail : ""}`); }
}

async function main() {
  const [owner, user1, user2] = await hre.ethers.getSigners();
  const E = hre.ethers;
  const ONE = 10n ** 18n;
  const parse = (n) => E.parseUnits(String(n), 18);

  // ── Fresh deployment ──────────────────────────────────────────────
  const MockUSDC = await E.getContractFactory("MockUSDC");
  const usdc = await MockUSDC.deploy();
  await usdc.waitForDeployment();

  const Vault = await E.getContractFactory("ProYieldVault");
  const vault = await Vault.deploy(await usdc.getAddress(), owner.address, owner.address);
  await vault.waitForDeployment();

  const usdcAddr = await usdc.getAddress();
  const vaultAddr = await vault.getAddress();

  const mintApprove = async (who, amount) => {
    let tx = await usdc.mint(who.address, amount);
    await tx.wait();
    tx = await usdc.connect(who).approve(vaultAddr, amount);
    await tx.wait();
  };

  // ── A1: defaults ─────────────────────────────────────────────────
  report("A1 defaults: tvlCap=0 (uncapped), perUserCap=0, depositsPaused=false",
    (await vault.tvlCap()) === 0n && (await vault.perUserCap()) === 0n && (await vault.depositsPaused()) === false);

  // ── A2–A4: TVL cap boundary + re-open ────────────────────────────
  let tx = await vault.setCaps(parse(1000), 0);
  await tx.wait();
  await mintApprove(user1, parse(2000));

  tx = await vault.connect(user1).deposit(parse(1000));
  await tx.wait();
  report("A2 deposit EXACTLY at the TVL cap passes", (await vault.totalAssets()) === parse(1000));

  let capMsg = false;
  try { tx = await vault.connect(user1).deposit(1n); await tx.wait(); }
  catch (e) { capMsg = String(e.message).includes("TVL cap reached"); }
  report("A3 one wei over the TVL cap reverts with message", capMsg);

  tx = await vault.connect(user1).withdraw(parse(100));
  await tx.wait();
  tx = await vault.connect(user1).deposit(parse(50));
  await tx.wait();
  report("A4 withdrawal re-opens TVL headroom (1000 − 100 + 50 = 950)",
    (await vault.totalAssets()) === parse(950));

  // ── A5–A6: per-user cap ──────────────────────────────────────────
  tx = await vault.setCaps(0, parse(600));
  await tx.wait();
  await mintApprove(user2, parse(2000));

  tx = await vault.connect(user2).deposit(parse(600));
  await tx.wait();
  report("A5 user2 fills to the per-user cap independently of user1",
    (await vault.totalAssets()) === parse(1550) && (await vault.shares(user2.address)) > 0n);

  capMsg = false;
  try { tx = await vault.connect(user2).deposit(1n); await tx.wait(); }
  catch (e) { capMsg = String(e.message).includes("per-user cap reached"); }
  report("A6 one wei over the per-user cap reverts with message", capMsg);

  // ── A7–A9: pause ─────────────────────────────────────────────────
  tx = await vault.setDepositsPaused(true);
  await tx.wait();

  capMsg = false;
  try { tx = await vault.connect(user1).deposit(1n); await tx.wait(); }
  catch (e) { capMsg = String(e.message).includes("deposits paused"); }
  report("A7 pause blocks deposits (message)", capMsg);

  const before = await usdc.balanceOf(user2.address);
  tx = await vault.connect(user2).withdraw(parse(50));
  await tx.wait();
  report("A8 withdrawals stay OPEN while paused (+50 to the user)",
    (await usdc.balanceOf(user2.address)) === before + parse(50));

  tx = await vault.setDepositsPaused(false);
  await tx.wait();
  tx = await vault.connect(user2).deposit(10n ** 12n); // tiny but above the dust floor
  await tx.wait();
  report("A9 unpause re-opens deposits", true);

  // ── A10–A11: owner-only ──────────────────────────────────────────
  let locked = false;
  try { tx = await vault.connect(user1).setCaps(1n, 1n); await tx.wait(); } catch { locked = true; }
  report("A10 setCaps is owner-only", locked);

  locked = false;
  try { tx = await vault.connect(user1).setDepositsPaused(true); await tx.wait(); } catch { locked = true; }
  report("A11 setDepositsPaused is owner-only", locked);

  // ── A12: zero caps restore uncapped behavior ─────────────────────
  tx = await vault.setCaps(0, 0);
  await tx.wait();
  const tvlBefore = await vault.totalAssets();
  tx = await vault.connect(user1).deposit(10n ** 12n);
  await tx.wait();
  report("A12 zero caps = uncapped (deposit beyond old limits passes)",
    (await vault.totalAssets()) > tvlBefore);

  console.log(`\nvault caps suite: ${pass} passed, ${fail} failed`);
  if (fail > 0) process.exit(1);
  process.exit(0);
}

main().catch((e) => { console.error(e); process.exit(2); });
