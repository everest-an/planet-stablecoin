import "@acton/testing/expect"
import "../planet_core"

// Unit tests for the PlanetCore pure math (1e6 fixed point, 0.5% fee).
// mintAmount = D * (1 - f) / PPI ; burnAmount = B * PPI * (1 - f)

get fun `test mint at PPI 1.0`() {
    // deposit 1.0 (1e6) at PPI 1.0 -> 0.995
    expect(mintAmount(1000000, 1000000)).toEqual(995000);
}

get fun `test mint at PPI 1.05`() {
    expect(mintAmount(1050000, 1050000)).toEqual(995000);
}

get fun `test burn at PPI 1.0`() {
    // burn 1.0 PLT at PPI 1.0 -> 0.995 USDC
    expect(burnAmount(1000000, 1000000)).toEqual(995000);
}

get fun `test mint then burn round trip`() {
    val minted = mintAmount(1000000, 1000000);
    val back = burnAmount(minted, 1000000);
    // two 0.5% fees -> 0.995 * 0.995 = 0.990025
    expect(back).toEqual(990025);
}

get fun `test mint decreases as PPI rises`() {
    // same deposit, higher PPI -> fewer PLT minted: 995000 * 1e6 / 1.1e6 = 904545
    expect(mintAmount(1000000, 1100000)).toEqual(904545);
}

get fun `test burn at PPI 1.05`() {
    // gross = 1.0 * 1.05 = 1.05; net = 1.05 * 0.995 = 1.04475 -> 1044750
    expect(burnAmount(1000000, 1050000)).toEqual(1044750);
}

get fun `test fee is 0.5%`() {
    expect(feeAmount(1000000)).toEqual(5000);
}

get fun `test fee split is 30/50/20`() {
    val (burn, reserve, staking) = feeSplit(10000);
    expect(burn).toEqual(3000);
    expect(reserve).toEqual(5000);
    expect(staking).toEqual(2000);
}

get fun `test RTRA drift is zero at target weight`() {
    // weight 50%, value 500 of totalReserve 1000 -> actual 50% -> drift 0
    expect(rebalanceDrift(500000, 500, 1000)).toEqual(0);
}

get fun `test RTRA triggers when drift exceeds 0.5%`() {
    // weight 50%, value 400 of 1000 -> actual 40% -> drift +10% -> rebalance
    expect(shouldRebalance(500000, 400, 1000)).toEqual(true);
    // at target -> no rebalance
    expect(shouldRebalance(500000, 500, 1000)).toEqual(false);
}

get fun `test fee split has no dust loss`() {
    // non-divisible fee: remainder must go to staking, sum preserved
    val (burn, reserve, staking) = feeSplit(999);
    expect(burn + reserve + staking).toEqual(999);
}

// C-1: with every asset frozen the index is UNDEFINED. It used to fall back to 1.0, which
// looked like a healthy peg and let minting proceed against a fabricated index.
get fun `test ppi is undefined when every asset is frozen`() {
    var assets: map<int64, CoreAsset> = [];
    assets.set(0, CoreAsset { weight: 500000, basePrice: 1000000, currentPrice: 1000000, volatility: 0, liquidity: 0, riskState: 2 });
    assets.set(1, CoreAsset { weight: 500000, basePrice: 1000000, currentPrice: 1000000, volatility: 0, liquidity: 0, riskState: 2 });
    expect(computePpi(assets, 2)).toEqual(0);
}

get fun `test ppi renormalises over the active assets only`() {
    // asset 0 frozen, asset 1 active at twice its base -> index reads 2.0 (weight-renormalised)
    var assets: map<int64, CoreAsset> = [];
    assets.set(0, CoreAsset { weight: 500000, basePrice: 1000000, currentPrice: 1000000, volatility: 0, liquidity: 0, riskState: 2 });
    assets.set(1, CoreAsset { weight: 500000, basePrice: 1000000, currentPrice: 2000000, volatility: 0, liquidity: 0, riskState: 0 });
    expect(computePpi(assets, 2)).toEqual(2000000);
}

get fun `test RTRA drift sign: underweight is positive`() {
    // target 50%, actual 40% -> positive drift (buy)
    expect(rebalanceDrift(500000, 400, 1000)).toEqual(100000);
    // target 50%, actual 60% -> negative drift (sell)
    expect(rebalanceDrift(500000, 600, 1000)).toEqual(-100000);
}

// ---------------- Large-value overflow regressions (int64 -> int) ----------------

get fun `test mint handles large deposits without int64 overflow`() {
    // $10M (1e13 in 6-dec): int64 would overflow in `net * PPI_SCALE`.
    expect(mintAmount(10000000000000, 1000000)).toEqual(9950000000000);
}

get fun `test burn handles large amounts without int64 overflow`() {
    // 1e13 PLT: int64 would overflow in `plt * ppi`.
    expect(burnAmount(10000000000000, 1000000)).toEqual(9950000000000);
}

get fun `test rebalance drift handles large position values`() {
    // positionValue 5e13 * WEIGHT_SCALE would overflow int64; at 50% of 1e14 drift is 0.
    expect(rebalanceDrift(500000, 50000000000000, 100000000000000)).toEqual(0);
}

// ---------------- Band fees (stability batch A) ----------------

get fun `test fee bps bands`() {
    expect(feeBpsForPpi(1000000)).toEqual(50);   // 0% dev  -> base
    expect(feeBpsForPpi(1020000)).toEqual(50);   // 2% dev  -> base
    expect(feeBpsForPpi(1040000)).toEqual(100);  // 4% dev  -> elevated
    expect(feeBpsForPpi(950000)).toEqual(100);   // 5% dev  -> elevated (boundary)
    expect(feeBpsForPpi(1100000)).toEqual(250);  // 10% dev -> 200 + slope 50
}

get fun `test band fee amount`() {
    expect(feeAmountAtPpi(1000000, 1000000)).toEqual(5000);  // 0.5%
    expect(feeAmountAtPpi(1000000, 1040000)).toEqual(10000); // 1.0%
    expect(feeAmountAtPpi(1000000, 1100000)).toEqual(25000); // 2.5% (200 + slope 50)
}

get fun `test fee slope beyond 5%`() {
    expect(feeBpsForPpi(1050000)).toEqual(100);  // 5% boundary -> still elevated band
    expect(feeBpsForPpi(1060000)).toEqual(210);  // 6%: 200 + (60000-50000)*1000/1e6
    expect(feeBpsForPpi(1100000)).toEqual(250);  // 10%: 200 + 50
    expect(feeBpsForPpi(1200000)).toEqual(350);  // 20%: 200 + 150
}

get fun `test burn fee asymmetry`() {
    expect(burnFeeBpsForPpi(1000000)).toEqual(50);  // peg
    expect(burnFeeBpsForPpi(1040000)).toEqual(100); // 4% up, no penalty
    expect(burnFeeBpsForPpi(960000)).toEqual(200);  // 4% down + penalty 100
    // received at PPI 0.96 with 2% redeem fee: gross 0.96 -> 0.96*0.98 = 0.9408
    expect(burnAmountAtPpi(1000000, 960000)).toEqual(940800);
}

get fun `test band mint amount off-peg`() {
    // near peg: 1.0 deposit -> 0.995 PLT
    expect(mintAmountAtPpi(1000000, 1000000)).toEqual(995000);
    // 4% off peg: 1.0% fee -> net 0.99, /1.04 -> 951923
    expect(mintAmountAtPpi(1000000, 1040000)).toEqual(951923);
}

get fun `test diffAbs`() {
    expect(diffAbs(1000000, 1100000)).toEqual(100000);
    expect(diffAbs(1100000, 1000000)).toEqual(100000);
    expect(diffAbs(1000000, 1000000)).toEqual(0);
}

// ---------------- Risk-aware RTRA (CAM inputs) ----------------

get fun `test risk-aware rebalance freezes at riskState 2`() {
    // large drift but frozen -> never rebalance
    expect(shouldRebalanceRisk(500000, 400, 1000, 0, 1000000, 2)).toEqual(false);
}

get fun `test risk-aware rebalance when calm`() {
    // 10% drift, zero vol, full liquidity, normal -> true
    expect(shouldRebalanceRisk(500000, 400, 1000, 0, 1000000, 0)).toEqual(true);
    // 0.5% drift is not > 0.5% -> false
    expect(shouldRebalanceRisk(500000, 495, 1000, 0, 1000000, 0)).toEqual(false);
}

get fun `test high volatility widens the rebalance threshold`() {
    // 1% drift (10000 ppm) > base threshold 5000 -> would trigger …
    expect(shouldRebalanceRisk(500000, 490, 1000, 0, 1000000, 0)).toEqual(true);
    // … but 100% volatility doubles the threshold to 10000 -> not strictly greater
    expect(shouldRebalanceRisk(500000, 490, 1000, 1000000, 1000000, 0)).toEqual(false);
}

get fun `test caution widens the threshold further`() {
    // 1% drift, calm inputs, but riskState=caution -> threshold doubled -> false
    expect(shouldRebalanceRisk(500000, 490, 1000, 0, 1000000, 1)).toEqual(false);
}

get fun `test low liquidity widens the rebalance threshold`() {
    // 1% drift, but 50% liquidity -> threshold scaled x2 -> not strictly greater
    expect(shouldRebalanceRisk(500000, 490, 1000, 0, 500000, 0)).toEqual(false);
}

get fun `test rebalanceDrift with zero reserve returns the weight`() {
    expect(rebalanceDrift(500000, 123, 0)).toEqual(500000);
}

get fun `test zero liquidity does not widen the threshold`() {
    // liquidity 0 -> the liquidity-scaling branch is skipped (true)
    expect(shouldRebalanceRisk(500000, 490, 1000, 0, 0, 0)).toEqual(true);
}

get fun `test shouldRebalance overweight position triggers`() {
    // 60% actual vs 50% target -> drift -100000 -> |drift| > threshold -> true
    expect(shouldRebalance(500000, 600, 1000)).toEqual(true);
}
