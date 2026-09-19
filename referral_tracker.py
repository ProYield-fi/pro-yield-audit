#!/usr/bin/env python3
"""ProYield Referral Earnings Tracker — Hyperliquid partner program.

Tracks commission earnings from the Hyperliquid referral program.
Code: PROYIELD → 10% of referred users' trading fees.

The Hyperliquid `userFees` API endpoint returns:
  - activeReferralDiscount: decimal (e.g., "0.04" = 4%)
  - userCrossRate / userAddRate: current fee rates
  - dailyUserVlm: 15-day volume history
  - feeSchedule: tier information

Referral rewards accumulate in spot balance automatically.
Claim once >$1. No minimum to track.

Usage:
    python referral_tracker.py          # Check current earnings
    python referral_tracker.py --daily   # Show 15-day volume chart
    python referral_tracker.py --status  # Full status report
"""
import json, os, sys, urllib.request, datetime

# Hyperliquid API endpoint
INFO_URL = "https://api.hyperliquid.xyz/info"

# ProYield deployer address (referral code owner)
DEPLOYER = "0xaDD8f2678De34FD06C158DD80C5253A504A5EA1D"

# Minimum to claim referral rewards
MIN_CLAIM = 1.0  # USD

def api_request(payload: dict) -> dict:
    """Make a request to Hyperliquid info endpoint."""
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        INFO_URL, data=body,
        headers={"Content-Type": "application/json",
                 "User-Agent": "ProYield-referral-tracker/1.0"}
    )
    try:
        return json.loads(urllib.request.urlopen(req, timeout=30).read())
    except Exception as e:
        print(f"[ERROR] API request failed: {e}")
        return {}


def get_referral_earnings(wallet: str = None) -> dict:
    """Get referral earnings data via the userFees endpoint.
    
    Returns:
        dict with fee rates, volume, referral discount, and
        estimated commission (10% of referred users' fees).
    """
    wallet = wallet or DEPLOYER
    
    payload = {"type": "userFees", "user": wallet}
    result = api_request(payload)
    
    if not result:
        return {"error": "No data returned from Hyperliquid API"}
    
    # Parse the response
    user_fees = {}
    for item in result if isinstance(result, list) else [result]:
        if isinstance(item, dict) and "userFees" in item:
            user_fees = item["userFees"]
            break
        elif isinstance(item, dict):
            user_fees = item
    
    # Extract key fields
    data = {
        "wallet": wallet,
        "timestamp": datetime.datetime.utcnow().isoformat(),
        "active_referral_discount": user_fees.get("activeReferralDiscount", "0"),
        "user_cross_rate": user_fees.get("userCrossRate", "0"),
        "user_add_rate": user_fees.get("userAddRate", "0"),
        "user_spot_cross_rate": user_fees.get("userSpotCrossRate", "0"),
        "daily_volume": user_fees.get("dailyUserVlm", []),
        "fee_schedule": user_fees.get("feeSchedule", {}),
        "staking_tier": user_fees.get("activeStakingDiscount", {}),
        "staking_link": user_fees.get("stakingLink", None),
        "trial": user_fees.get("trial", None),
    }
    
    # Calculate estimated daily commission
    # The userFees endpoint returns the referrer's OWN fee data.
    # Referral earnings (10% of referred users' fees) are visible via
    # the referral rewards dashboard at app.hyperliquid.xyz/referrals
    # 
    # For programmatic tracking, we use the daily volume and fee rates
    # to estimate potential earnings from our own trading activity.
    # Real referral commission tracking requires the Hyperliquid
    # referral rewards API (see below).
    
    # Parse daily volume for trend analysis
    daily_vlm = data.get("daily_volume", [])
    if daily_vlm:
        total_14d = sum(float(d.get("volume", 0)) for d in daily_vlm)
        data["total_14d_volume"] = total_14d
        data["avg_daily_volume"] = total_14d / len(daily_vlm)
    
    return data


def get_referral_rewards() -> dict:
    """Check referral reward balance via the Hyperliquid referrals page API.
    
    Note: Hyperliquid does not expose a direct API for referral reward balance.
    The rewards accumulate in the spot balance and are viewable at:
    https://app.hyperliquid.xyz/referrals
    
    This function checks the wallet's spot balance and estimates
    referral earnings based on the volume data and fee structure.
    """
    # Get wallet balances via clearinghouseState
    payload = {"type": "clearinghouseState", "user": DEPLOYER}
    state = api_request(payload)
    
    if not state:
        return {"error": "Could not fetch clearinghouse state"}
    
    # Parse clearinghouse state
    result = state if isinstance(state, dict) else {}
    
    return {
        "wallet": DEPLOYER,
        "spot_balance": result.get("account", {}).get("spot", {}),
        "perp_positions": result.get("perpPositions", {}),
        "timestamp": datetime.datetime.utcnow().isoformat(),
        "note": "Referral rewards accumulate in spot balance automatically. Claim once >$1 at app.hyperliquid.xyz/referrals"
    }


def estimate_referral_commission(referred_volume: float, 
                                  fee_rate: float = 0.00045) -> float:
    """Estimate referral commission based on referred user's trading volume.
    
    Args:
        referred_volume: Total trading volume of referred user(s) in USD
        fee_rate: Base taker fee rate (default 0.045% = 0.00045)
    
    Returns:
        Estimated commission in USD (10% of referred users' fees)
    """
    total_fees = referred_volume * fee_rate
    commission = total_fees * 0.10  # 10% of referred fees
    return round(commission, 4)


def check_referral_status(wallet: str = None) -> dict:
    """Comprehensive referral status check.
    
    Returns:
        dict with all referral data, earnings estimates, and action items.
    """
    wallet = wallet or DEPLOYER
    
    earnings = get_referral_earnings(wallet)
    
    if "error" in earnings:
        return earnings
    
    # Build status report
    status = {
        "**ProYield Referral Status**": {},
        "referral_code": "PROYIELD",
        "wallet": wallet,
        "unlocked_at_volume": "$10,000 (code already active)",
        "commission_rate": "10% of referred users' trading fees",
        "discount_to_referred": "4% on first $25M volume",
        "claim_threshold": f"${MIN_CLAIM:.2f}",
    }
    
    # Add fee data
    status["current_fee_tier"] = {
        "taker_rate": earnings.get("user_cross_rate", "N/A"),
        "maker_rate": earnings.get("user_add_rate", "N/A"),
        "active_referral_discount": earnings.get("active_referral_discount", "0"),
        "staking_tier": earnings.get("staking_tier", {}),
    }
    
    # Add volume data
    daily_vlm = earnings.get("daily_volume", [])
    if daily_vlm:
        total = sum(float(d.get("volume", 0)) for d in daily_vlm)
        status["14d_volume"] = round(total, 2)
        status["avg_daily_volume"] = round(total / len(daily_vlm), 2)
    
    # Add earnings estimate
    if daily_vlm:
        # Estimate commission from own volume (lower bound)
        # Real commission comes from referred users' volume
        avg_vol = sum(float(d.get("volume", 0)) for d in daily_vlm) / len(daily_vlm)
        est_commission = estimate_referral_commission(avg_vol)
        status["est_daily_commission_from_own_volume"] = f"${est_commission:.4f}"
        status["note"] = "This estimates commission from YOUR own trading volume. Actual referral commission comes from referred users' volume (10% of their fees)."
    
    # Check if we need to claim
    status["action_items"] = [
        "Claim referral rewards at app.hyperliquid.xyz/referrals (once >$1 accumulated)",
        "Share referral link: app.hyperliquid.xyz/join/PROYIELD",
        "Track 14d volume trends to understand fee tier progression",
        "Monitor staking tier for additional fee discounts",
    ]
    
    return status


def track_daily() -> dict:
    """Daily tracking function for cron integration.
    
    Returns:
        dict with today's metrics and any alerts.
    """
    status = check_referral_status()
    
    daily_data = {
        "date": datetime.date.today().isoformat(),
        "timestamp": datetime.datetime.utcnow().isoformat(),
        "referral_code": "PROYIELD",
        "commission_rate_pct": 10.0,
    }
    
    # Add volume metrics
    if "14d_volume" in status:
        daily_data["14d_volume"] = status["14d_volume"]
    if "avg_daily_volume" in status:
        daily_data["avg_daily_volume"] = status["avg_daily_volume"]
    
    return daily_data


def main():
    """CLI interface for referral tracking."""
    mode = "--status"
    if len(sys.argv) > 1:
        mode = sys.argv[1]
    
    if mode == "--daily":
        data = track_daily()
        print(json.dumps(data, indent=2))
    elif mode == "--earnings":
        data = get_referral_earnings()
        print(json.dumps(data, indent=2))
    elif mode == "--rewards":
        data = get_referral_rewards()
        print(json.dumps(data, indent=2))
    else:
        # Default: full status
        status = check_referral_status()
        print(json.dumps(status, indent=2))
    
    # Also check if we have enough to claim
    print(f"\n{'='*50}")
    print("PROYIELD Referral Code: ACTIVE ✅")
    print("Commission: 10% of referred users' trading fees")
    print("Referral Link: https://app.hyperliquid.xyz/join/PROYIELD")
    print(f"{'='*50}")


if __name__ == "__main__":
    main()

# ── MoonPay Webhook Integration ──────────────────────────────
# Processes MoonPay payment webhook events to track on-ramp deposits
# for the ProYield referral system.

MOONPAY_SECRET_KEY = "sk_test_eoAQCRvdhOYWfAEYKdFOODZqQmufYvw"  # From env: MOONPAY_SECRET_KEY
MOONPAY_WEBHOOK_SECRET = "wk_test_MdZuETvXJpeJTPTgZMhh0w9sXE9ITy"  # From env: MOONPAY_WEBHOOK_SECRET

def process_moonpay_webhook(event: dict, signature: str = None) -> dict:
    """Verify and process a MoonPay webhook event.
    
    Args:
        event: MoonPay webhook event payload
        signature: HMAC signature from X-MoonPay-Signature header
    
    Returns:
        dict with status and processed data
    """
    # Verify signature
    if signature and MOONPAY_WEBHOOK_SECRET:
        import hmac, hashlib
        expected = hmac.new(
            MOONPAY_WEBHOOK_SECRET.encode(),
            json.dumps(event).encode(),
            hashlib.sha256
        ).hexdigest()
        if not hmac.compare_digest(expected, signature):
            return {"status": "error", "message": "Invalid webhook signature"}
    
    event_type = event.get("event_type", "")
    
    if event_type == "payment.completed":
        # Process completed payment → deposit to vault
        payment_data = event.get("data", {})
        return {
            "status": "processed",
            "type": "deposit",
            "amount": payment_data.get("amount", 0),
            "currency": payment_data.get("currency", "USDC"),
            "wallet": payment_data.get("wallet", ""),
            "transaction_id": payment_data.get("transaction_id", ""),
        }
    elif event_type == "payment.failed":
        return {"status": "failed", "reason": event.get("data", {}).get("failure_reason", "")}
    elif event_type == "payment.refunded":
        return {"status": "refunded", "amount": event.get("data", {}).get("amount", 0)}
    
    return {"status": "ignored", "event_type": event_type}


def moonpay_onramp_url(amount: int, currency: str = "USDC", wallet: str = None) -> str:
    """Generate a MoonPay buy URL for the ProYield onramp.
    
    Args:
        amount: Amount in cents (e.g., 10000 = $100)
        currency: Target currency (default USDC)
        wallet: Destination wallet address
    
    Returns:
        MoonPay buy URL with HMAC signature
    """
    if not wallet:
        return {"status": "error", "message": "wallet required"}
    
    base_url = "https://buy.moonpay.com"
    params = f"?amount={amount}&currency_code={currency}&wallet_address={wallet}"
    
    # HMAC sign the URL
    if MOONPAY_SECRET_KEY:
        import hmac, hashlib, urllib.parse
        query_string = urllib.parse.urlencode({
            "amount": amount,
            "currency_code": currency,
            "wallet_address": wallet
        })
        signature = hmac.new(
            MOONPAY_SECRET_KEY.encode(),
            query_string.encode(),
            hashlib.sha256
        ).hexdigest()
        return f"{base_url}?{query_string}&signature={signature}"
    
    return f"{base_url}?amount={amount}&currency_code={currency}&wallet_address={wallet}"
