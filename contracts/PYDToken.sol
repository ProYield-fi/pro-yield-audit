// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ProYield token (PYD) — fixed supply, minted once at deploy to the
/// deployer, then distributed per the published allocation.
///
/// Standard OpenZeppelin ERC20: Transfer/Approval events and the full surface
/// so wallets, explorers, DEXes and HyperCore/HIP-1 tooling work with no
/// special-casing. Unlike the earlier minimal token (no events, custom
/// internals) this is the contract every integration expects.
///
/// No mint function — supply is immutable and verifiable on-chain.
///
/// SUPPLY CONVENTION: the constructor scales by 10**18 internally — pass the
/// WHOLE-TOKEN count (e.g. 100000000 for 100M tokens, the decided supply).
/// Passing parseUnits(...,18) double-scales to 1e18x the intended supply
/// (found on the earlier deploy 2026-09-20).
contract PYDToken is ERC20 {
    constructor(uint256 _initialSupply) ERC20("ProYield", "PYD") {
        require(_initialSupply > 0, "PYDToken: zero supply");
        _mint(msg.sender, _initialSupply * 10 ** 18);
    }
}
