// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal vendored subset of hyperliquid-dev/hyper-evm-lib HLConstants (MIT).
/// Source: https://github.com/hyperliquid-dev/hyper-evm-lib — only the constants
/// the DN adapter needs. Mainnet = chainid 999, testnet = 998 (anvil also 998).
library HLConstants {
    /*//////////////////////// Read precompiles ////////////////////////*/
    // HyperCore state as of EVM block construction. Gas: 2000 + 65 * output_len.
    address internal constant POSITION2_PRECOMPILE = 0x0000000000000000000000000000000000000813;
    address internal constant WITHDRAWABLE_PRECOMPILE = 0x0000000000000000000000000000000000000803;
    address internal constant MARK_PX_PRECOMPILE = 0x0000000000000000000000000000000000000806;
    address internal constant ORACLE_PX_PRECOMPILE = 0x0000000000000000000000000000000000000807;
    address internal constant PERP_ASSET_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080a;
    address internal constant ACCOUNT_MARGIN_SUMMARY_PRECOMPILE = 0x000000000000000000000000000000000000080F;
    address internal constant CORE_USER_EXISTS_PRECOMPILE = 0x0000000000000000000000000000000000000810;
    address internal constant SPOT_BALANCE_PRECOMPILE = 0x0000000000000000000000000000000000000801;
    address internal constant SPOT_PX_PRECOMPILE = 0x0000000000000000000000000000000000000808;
    address internal constant SPOT_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080b;
    address internal constant TOKEN_INFO_PRECOMPILE = 0x000000000000000000000000000000000000080C;

    /*//////////////////////// Bridge / system ////////////////////////*/
    address internal constant HYPE_SYSTEM_ADDRESS = 0x2222222222222222222222222222222222222222;
    uint160 internal constant BASE_SYSTEM_ADDRESS = uint160(0x2000000000000000000000000000000000000000);

    address internal constant USDC_EVM_CONTRACT = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
    address internal constant TESTNET_USDC_CONTRACT = 0x2B3370eE501B4a559b57D449569354196457D8Ab;
    address internal constant CORE_DEPOSIT_WALLET = 0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24;
    address internal constant TESTNET_CORE_DEPOSIT_WALLET = 0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206;

    uint64 internal constant USDC_TOKEN_INDEX = 0;

    /*//////////////////////// CoreWriter action IDs ////////////////////////*/
    uint24 internal constant LIMIT_ORDER_ACTION = 1;
    uint24 internal constant TOKEN_DELEGATE_ACTION = 3;
    uint24 internal constant STAKING_DEPOSIT_ACTION = 4;
    uint24 internal constant STAKING_WITHDRAW_ACTION = 5;
    uint24 internal constant SPOT_SEND_ACTION = 6;
    uint24 internal constant USD_CLASS_TRANSFER_ACTION = 7;
    uint24 internal constant CANCEL_ORDER_BY_CLOID_ACTION = 11;
    uint24 internal constant SEND_ASSET_ACTION = 13;

    /*//////////////////////// Time in force ////////////////////////*/
    uint8 internal constant TIF_ALO = 1;
    uint8 internal constant TIF_GTC = 2;
    uint8 internal constant TIF_IOC = 3;

    /*//////////////////////// Dex ////////////////////////*/
    uint32 internal constant SPOT_DEX = type(uint32).max;

    function isTestnet() internal view returns (bool) {
        return block.chainid == 998;
    }

    function usdc() internal view returns (address) {
        return isTestnet() ? TESTNET_USDC_CONTRACT : USDC_EVM_CONTRACT;
    }

    function coreDepositWallet() internal view returns (address) {
        return isTestnet() ? TESTNET_CORE_DEPOSIT_WALLET : CORE_DEPOSIT_WALLET;
    }
}
