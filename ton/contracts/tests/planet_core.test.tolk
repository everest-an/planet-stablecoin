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

get fun `test mint increases with PPI`() {
    // same deposit, higher PPI -> fewer PLT minted
    expect(mintAmount(1000000, 1100000)).toBeLessThan(mintAmount(1000000, 1000000));
}
