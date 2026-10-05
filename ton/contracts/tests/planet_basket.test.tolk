import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@wrappers/PlanetBasket.gen"

// PlanetBasket tests: the on-chain commodity basket registry (assetCount / assetAt /
// owner-gated SetAsset). Previously untested.

fun deployBasket(): (PlanetBasket, Treasury, Treasury) {
    val owner = testing.treasury("owner");
    val outsider = testing.treasury("outsider");
    val basket = PlanetBasket.fromStorage({
        owner: owner.address,
        assetCount: 0,
        assets: [],
    });
    expect(basket.deploy(owner.address, { value: ton("0.2") }))
        .toHaveSuccessfulDeploy({ to: basket.address });
    return (basket, owner, outsider);
}

get fun `test owner can set asset and read it back`() {
    val (basket, owner, _) = deployBasket();
    // index 0, weight 50%, base/current price 1.0, position value 1.0
    basket.sendSetAsset(owner.address, 0, 0, 500000, 1000000, 1000000, 1000000, { value: ton("0.05") });
    expect(basket.assetCount()).toEqual(1);
    val a = basket.assetAt(0);
    expect(a.weight).toEqual(500000);
    expect(a.basePrice).toEqual(1000000);
    expect(a.currentPrice).toEqual(1000000);
    expect(a.positionValue).toEqual(1000000);
}

get fun `test setting a high index grows assetCount`() {
    val (basket, owner, _) = deployBasket();
    basket.sendSetAsset(owner.address, 0, 2, 250000, 1000000, 1000000, 1000000, { value: ton("0.05") });
    expect(basket.assetCount()).toEqual(3);
}

get fun `test updating an existing index keeps count`() {
    val (basket, owner, _) = deployBasket();
    basket.sendSetAsset(owner.address, 0, 0, 500000, 1000000, 1000000, 1000000, { value: ton("0.05") });
    basket.sendSetAsset(owner.address, 0, 0, 600000, 1000000, 1000000, 1000000, { value: ton("0.05") });
    expect(basket.assetCount()).toEqual(1);
    expect(basket.assetAt(0).weight).toEqual(600000);
}

get fun `test non-owner cannot set asset`() {
    val (basket, _, outsider) = deployBasket();
    val res = basket.sendSetAsset(outsider.address, 0, 0, 500000, 1000000, 1000000, 1000000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: outsider.address, to: basket.address, exitCode: 101 });
    expect(basket.assetCount()).toEqual(0);
}

get fun `test unknown opcode is rejected`() {
    val (basket, owner, _) = deployBasket();
    val res = basket.sendAny(owner.address, beginCell().storeUint(0xDEADBEEF, 32).endCell(), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: owner.address, to: basket.address, exitCode: 65535 });
}
