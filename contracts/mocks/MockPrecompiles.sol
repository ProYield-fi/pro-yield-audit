// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Mock read-precompiles. The real precompiles take raw ABI-encoded
/// args (no selector) via staticcall; these mocks expose setters for tests and
/// a fallback that returns the canned struct. Copied to the fixed precompile
/// addresses (0x810, 0x813, 0x80f, 0x803, 0x80a, 0x807) via anvil_setCode.
///
/// Each fallback ASSERTS the real calldata shape (verified against mainnet on
/// 2026-09-20) so a wrong encoding reverts in tests instead of silently
/// passing — the exact trap the accountMarginSummary(dex,user) bug slipped
/// through before real-chain verification.

contract MockCoreUserExists {
    bool public exists;

    function setExists(bool e) external {
        exists = e;
    }

    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 32, "bad calldata shape (exists: address)");
        return abi.encode(exists);
    }
}

contract MockPosition2 {
    int64 public szi;
    uint64 public entryNtl;
    int64 public isolatedRawUsd;
    uint32 public leverage;
    bool public isIsolated;

    function set(int64 szi_, uint64 entryNtl_, int64 iso_, uint32 lev_, bool isIso_) external {
        szi = szi_;
        entryNtl = entryNtl_;
        isolatedRawUsd = iso_;
        leverage = lev_;
        isIsolated = isIso_;
    }

    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 64, "bad calldata shape (position: address,uint32)");
        return abi.encode(szi, entryNtl, isolatedRawUsd, leverage, isIsolated);
    }
}

contract MockMarginSummary {
    int64 public accountValue;
    uint64 public marginUsed;
    uint64 public ntlPos;
    int64 public rawUsd;

    function set(int64 av, uint64 mu, uint64 np, int64 ru) external {
        accountValue = av;
        marginUsed = mu;
        ntlPos = np;
        rawUsd = ru;
    }

    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 64, "bad calldata shape (marginSummary: uint32,address)");
        return abi.encode(accountValue, marginUsed, ntlPos, rawUsd);
    }
}

contract MockWithdrawable {
    uint64 public amount;

    function setAmount(uint64 a) external {
        amount = a;
    }

    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 32, "bad calldata shape (withdrawable: address)");
        return abi.encode(amount);
    }
}

contract MockPerpInfo {
    string public coin;
    uint32 public marginTableId;
    uint8 public szDecimals;
    uint8 public maxLeverage;
    bool public onlyIsolated;

    struct PerpAssetInfo {
        string coin;
        uint32 marginTableId;
        uint8 szDecimals;
        uint8 maxLeverage;
        bool onlyIsolated;
    }

    function set(string calldata coin_, uint32 mt_, uint8 sz_, uint8 ml_, bool oi_) external {
        coin = coin_;
        marginTableId = mt_;
        szDecimals = sz_;
        maxLeverage = ml_;
        onlyIsolated = oi_;
    }

    // Dynamic struct: the real precompile returns the 1-tuple encoding
    // (offset-wrapped) — verified against mainnet. abi.encode(Struct(...))
    // mirrors that exactly; direct field encoding would fail the contract's
    // abi.decode(ret, (Struct)).
    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 32, "bad calldata shape (perpAssetInfo: uint32)");
        return abi.encode(PerpAssetInfo(coin, marginTableId, szDecimals, maxLeverage, onlyIsolated));
    }
}

contract MockOraclePx {
    uint64 public px;

    function setPx(uint64 p) external {
        px = p;
    }

    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 32, "bad calldata shape (oraclePx: uint32)");
        return abi.encode(px);
    }
}
