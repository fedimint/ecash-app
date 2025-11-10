# Manual Testing Checklist

## Setup
**Build selection:**
- **New onboarding flow?** Use `.master` build for fresh install testing
- **Otherwise:** Upgrade existing release build to preserve mainnet funds and tx history

Note: Future Fedimint releases will reissue all ecash on recovery, which costs sats. Avoiding unnecessary reinstalls saves money over many release cycles.

## Federation
- [ ] Join mutinynet fed (if upgrading: leave first, then rejoin)

## On-chain
- [ ] Faucet → Mobile receive (verify pending, conf updates, smooth transition)
- [ ] Faucet → Desktop receive (verify pending, conf updates, smooth transition)
- [ ] Desktop → Faucet send
- [ ] Mobile → Faucet send

## Lightning
- [ ] Mobile → Desktop (scan bolt11 QR code)
- [ ] Mobile → Desktop (paste bolt11 string)
- [ ] Mobile → Faucet refund (refund@lnurl.mutinynet.com)
- [ ] Desktop → Faucet refund (refund@lnurl.mutinynet.com)
- [ ] Desktop → Mobile (paste bolt11 string)
- [ ] Faucet → Mobile (paste bolt11 string)
- [ ] Faucet → Desktop (paste bolt11 string)

## Ecash
- [ ] Mobile → Desktop (paste)
- [ ] Desktop → Mobile (paste)
- [ ] Desktop → Mobile (QR code)
- [ ] Mobile refund before claim (test check claim + redeem for both claimed/unclaimed)
- [ ] Desktop refund before claim (test check claim + redeem for both claimed/unclaimed)

## Recovery (CAUTION: requires uninstall, be aware of any mainnet sats)
- [ ] Desktop
- [ ] Mobile

## Mainnet Only (for now)
- [ ] Receive LN Address (either mobile → desktop or desktop → mobile)
- [ ] NWC
