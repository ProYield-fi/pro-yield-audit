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


contract MockSpotBalance {
    uint64 public total;
    uint64 public hold;
    uint64 public entryNtl;

    function set(uint64 t, uint64 h, uint64 e) external {
        total = t;
        hold = h;
        entryNtl = e;
    }

    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 64, "bad calldata shape (spotBalance: address,uint64)");
        return abi.encode(total, hold, entryNtl);
    }
}

contract MockSpotPx {
    uint64 public px;

    function setPx(uint64 p) external {
        px = p;
    }

    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 32, "bad calldata shape (spotPx: uint64)");
        return abi.encode(px);
    }
}

contract MockSpotInfo {
    struct SpotInfo {
        string name;
        uint64[2] tokens;
    }

    string public name;
    uint64[2] public toks;

    function set(string calldata n, uint64 t0, uint64 t1) external {
        name = n;
        toks[0] = t0;
        toks[1] = t1;
    }

    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 32, "bad calldata shape (spotInfo: uint64)");
        return abi.encode(SpotInfo(name, toks));
    }
}

contract MockTokenInfo {
    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    string public name;
    uint8 public szDecimals;
    uint8 public weiDecimals;

    function set(string calldata n, uint8 sz_, uint8 wd_) external {
        name = n;
        szDecimals = sz_;
        weiDecimals = wd_;
    }

    fallback(bytes calldata _data) external returns (bytes memory) {
        require(_data.length == 32, "bad calldata shape (tokenInfo: uint64)");
        uint64[] memory sp = new uint64[](1);
        sp[0] = 107;
        return abi.encode(TokenInfo(name, sp, 0, address(0), address(0), szDecimals, weiDecimals, int8(0)));
    }
}
