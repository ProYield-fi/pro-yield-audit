// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HLConstants} from "./HLConstants.sol";

/// @title HLEarnLib — CoreWriter action-15 (borrow/lend) encoder
/// @notice Wire format (mapped 2026-09-30 against Hyperliquid references):
///         abi.encodePacked(uint8(1), uint24(15), abi.encode(uint8 operation, uint64 token, uint64 wei))
///         - operation: 0 = Supply, 1 = Withdraw (no borrow/repay exists on the wire)
///         - token: reserve token index (0 = USDC); the wire field is uint64
///         - wei: amount in wire units — EXACT scale pinned by the testnet probe
///           (see docs/HLEARN_SLEEVE_DESIGN.md §Open questions); on Withdraw,
///           wei = 0 withdraws the full reserve balance
/// @dev Encoder ONLY — nothing here sends transactions. The HL Earn sleeve will
///      send these through ICoreWriter.sendRawAction with the same guard rails
///      as DNCoreBase (coreAccountRequired, verify-by-read, staged flows).
library HLEarnLib {
    uint8 internal constant OP_SUPPLY = 0;
    uint8 internal constant OP_WITHDRAW = 1;
    uint64 internal constant USDC_RESERVE = 0;

    function encodeSupply(uint64 token, uint64 weiAmount) internal pure returns (bytes memory) {
        return _encode(OP_SUPPLY, token, weiAmount);
    }

    function encodeWithdraw(uint64 token, uint64 weiAmount) internal pure returns (bytes memory) {
        return _encode(OP_WITHDRAW, token, weiAmount);
    }

    /// @dev wei = 0 means "withdraw the full reserve balance" per the wire spec.
    function encodeWithdrawMax(uint64 token) internal pure returns (bytes memory) {
        return _encode(OP_WITHDRAW, token, 0);
    }

    function _encode(uint8 operation, uint64 token, uint64 weiAmount) private pure returns (bytes memory) {
        return abi.encodePacked(uint8(1), HLConstants.BORROW_LEND_ACTION, abi.encode(operation, token, weiAmount));
    }
}
