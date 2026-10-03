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

get fun `test fee split is 45/30/25`() {
    val (burn, reserve, staking) = feeSplit(10000);
    expect(burn).toEqual(4500);
    expect(reserve).toEqual(3000);
    expect(staking).toEqual(2500);
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

get fun `test RTRA drift sign: underweight is positive`() {
    // target 50%, actual 40% -> positive drift (buy)
    expect(rebalanceDrift(500000, 400, 1000)).toEqual(100000);
    // target 50%, actual 60% -> negative drift (sell)
    expect(rebalanceDrift(500000, 600, 1000)).toEqual(-100000);
}
