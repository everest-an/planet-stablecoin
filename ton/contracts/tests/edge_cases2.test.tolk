import "@acton/testing/expect"
import "@acton/emulation/testing"
import "@acton/emulation/network"
import "@acton/crypto"
import "@wrappers/PlanetCore.gen"
import "@contracts/oracle_state"
import "@contracts/limits"
import "@contracts/signed_price"

// Additional error/branch coverage for PlanetCore handlers: arb rebate (rich index),
// redeem penalty (low PPI), all-frozen PPI fallback, and N-signature all-invalid.

fun coreWith(
    ppi: int64, paused: bool, maxPerTx: int64, riskFund: int64, baseLocked: bool,
    supply: int64, reserve: int64,
): (PlanetCore, Treasury, Treasury) {
    val deployer = testing.treasury("deployer");
    val minter = testing.treasury("minter");
    val core = PlanetCore.fromStorage({
        owner: deployer.address,
        jettonMinter: minter.address,
        totalReserve: reserve,
        totalSupply: supply,
        currentPpi: ppi,
        feesToBurn: 0,
        feesToReserve: 0,
        feesToStaking: 0,
        paused: paused,
        assets: [],
        cams: [],
        assetCount: 0,
        baseLocked: baseLocked,
        oracleState: OracleState { oracle: deployer.address, signerCount: 0, threshold: 0, signers: [], lastOracleUpdate: 0 }.toCell(),
        limitsState: Limits { maxPerTx: maxPerTx, arbRebateBps: 0, riskFund: riskFund }.toCell(),
    });
    expect(core.deploy(deployer.address, { value: ton("0.3") }))
        .toHaveSuccessfulDeploy({ to: core.address });
    return (core, deployer, minter);
}

fun sigCell(sig: slice): cell { return beginCell().storeSlice(sig).endCell(); }
fun domCell(payload: cell, core: address): cell {
    return beginCell().storeUint(0x504C4E54, 32).storeAddress(core).storeRef(payload).endCell();
}
fun pl1(index: int64, price: int64, ts: int64): cell {
    return PricePayload { queryId: 0, index, price, volatility: 0, liquidity: 1000000, riskState: 0, timestamp: ts }.toCell();
}
fun sigsCell2(a: cell, b: cell): cell {
    return beginCell().storeUint(2, 8).storeRef(a).storeRef(b).endCell();
}

// rich index (PPI > BAND_RICH) + arb rebate larger than the fee -> effective fee clamps to 0.
get fun `test mint with arb rebate above the fee clamps to zero`() {
    val (core, deployer, _) = coreWith(1040000, false, 0, 0, false, 0, 0);
    core.sendSetArb(deployer.address, 0, 500, { value: ton("0.05") });
    core.sendMint(deployer.address, 0, 1000000, { value: ton("1") });
    expect(core.supply()).toEqual(961538); // 1e6 * 1e6 / 1040000, no fee
}

// PPI below the redeem-penalty threshold adds the extra redeem fee.
get fun `test redeem below penalty threshold charges the extra fee`() {
    val (core, _, minter) = coreWith(960000, false, 0, 0, false, 1000000, 1000000);
    core.sendBurnMirror(minter.address, 0, 1000000, { value: ton("0.05") });
    expect(core.reserve()).toEqual(59200); // 1e6 - 1e6*0.96*(1-0.02)
}

// all assets frozen -> computePpi falls back to 1.0 (den == 0 branch).
get fun `test ppi falls back when all assets are frozen`() {
    val (core, deployer, minter) = coreWith(1000000, false, 0, 0, false, 0, 0);
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    core.sendSetCam(deployer.address, 0, 0, minter.address, { value: ton("0.05") });
    core.sendCamUpdate(minter.address, 0, 0, 1000000, 0, 1000000, 2, 1000, { value: ton("0.05") });
    expect(core.ppi()).toEqual(1000000);
    expect(core.assetAt(0).riskState).toEqual(2);
}

// N-signature update where no signature is valid -> matched == 0 -> ERR_BAD_SIG.
get fun `test n-signature update with no valid signer is rejected`() {
    val (core, deployer, relayer) = coreWith(1000000, false, 0, 0, false, 0, 0);
    val a = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 1, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val payload = pl1(0, 1100000, 1000);
    val other = crypto.createMnemonic().toKeyPair();
    val bad = sigCell(crypto.sign(other.privateKey, domCell(payload, core.address)));
    val sigs = sigsCell2(bad, bad);
    val res = core.sendSignedPriceUpdateN(relayer.address, sigs, payload, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 114 });
}
