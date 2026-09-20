// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice CoreWriter system contract — send HyperCore actions from an EVM contract.
/// The action runs as the CALLING CONTRACT's HyperCore user. Fire-and-forget:
/// no revert on drop — verify via reads (see docs/DN_COREWRITER_ADAPTER.md).
interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

/// @notice USDC EVM→Core deposit wallet (Hyperliquid system contract).
interface ICoreDepositWallet {
    function deposit(uint256 amount, uint32 destinationDex) external;
    function depositFor(address recipient, uint256 amount, uint32 destinationDex) external;
}
