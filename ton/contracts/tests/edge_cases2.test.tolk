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

// SetSigner: overwriting an existing slot must NOT grow signerCount (index < count path).
get fun `test SetSigner can overwrite an existing slot`() {
    val (core, deployer, _) = coreWith(1000000, false, 0, 0, false, 0, 0);
    val a = crypto.createMnemonic().toKeyPair();
    val b = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetSigner(deployer.address, 0, 0, b.publicKey as uint256, { value: ton("0.05") });
    expect(core.signerCount()).toEqual(1);
    expect(core.signerAt(0)).toEqual(b.publicKey);
}

get fun `test SetThreshold by non-owner is rejected`() {
    val (core, _, minter) = coreWith(1000000, false, 0, 0, false, 0, 0);
    val res = core.sendSetThreshold(minter.address, 0, 1, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: minter.address, to: core.address, exitCode: 101 });
}

get fun `test SetCam by non-owner is rejected`() {
    val (core, _, minter) = coreWith(1000000, false, 0, 0, false, 0, 0);
    val res = core.sendSetCam(minter.address, 0, 0, minter.address, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: minter.address, to: core.address, exitCode: 101 });
}

get fun `test signed update with a bad index is rejected`() {
    val (core, deployer, relayer) = coreWith(1000000, false, 0, 0, false, 0, 0);
    val a = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 1, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val p = pl1(5, 1100000, 1000);
    val res = core.sendSignedPriceUpdate(relayer.address, sigCell(crypto.sign(a.privateKey, domCell(p, core.address))), beginCell().endCell(), p, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: relayer.address, to: core.address, exitCode: 109 });
}

// A price DROP inside the band covers diffAbs' negative path (newPrice < oldPrice).
get fun `test signed update with a price drop is accepted`() {
    val (core, deployer, relayer) = coreWith(1000000, false, 0, 0, false, 0, 0);
    val a = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    core.sendSetThreshold(deployer.address, 0, 1, { value: ton("0.05") });
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val p = pl1(0, 900000, 1000);
    core.sendSignedPriceUpdate(relayer.address, sigCell(crypto.sign(a.privateKey, domCell(p, core.address))), beginCell().endCell(), p, { value: ton("0.05") });
    expect(core.ppi()).toEqual(900000);
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

// short-circuit branch: maxPerTx > 0 AND amount <= cap (the allowed case)
get fun `test mint within the per-tx cap succeeds`() {
    val (core, deployer, _) = coreWith(1000000, false, 2000000, 0, false, 0, 0);
    core.sendMint(deployer.address, 0, 1000000, { value: ton("1") });
    expect(core.supply()).toEqual(995000);
}

// short-circuit branch: arbRebateBps > 0 AND PPI <= BAND_RICH (rebate not applied)
get fun `test arb rebate set but index not rich`() {
    val (core, deployer, _) = coreWith(1000000, false, 0, 0, false, 0, 0);
    core.sendSetArb(deployer.address, 0, 500, { value: ton("0.05") });
    core.sendMint(deployer.address, 0, 1000000, { value: ton("1") });
    expect(core.supply()).toEqual(995000);
}

// Exercise every getter (many were never called → uncovered branches).
get fun `test all core getters are readable`() {
    val (core, deployer, minter) = coreWith(1000000, false, 0, 0, false, 0, 0);
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    core.sendSetCam(deployer.address, 0, 0, minter.address, { value: ton("0.05") });
    val a = crypto.createMnemonic().toKeyPair();
    core.sendSetSigner(deployer.address, 0, 0, a.publicKey as uint256, { value: ton("0.05") });
    expect(core.assetAt(0).weight).toEqual(1000000);
    expect(core.camAt(0)).toEqual(minter.address);
    expect(core.signerAt(0)).toEqual(a.publicKey);
    expect(core.owner()).toEqual(deployer.address);
    expect(core.oracle()).toEqual(deployer.address);
    expect(core.jettonMinter()).toEqual(minter.address);
    expect(core.lastOracleUpdate()).toEqual(0);
    expect(core.maxPerTx()).toEqual(0);
    expect(core.arbRebateBps()).toEqual(0);
    expect(core.signerCount()).toEqual(1);
    expect(core.threshold()).toEqual(0);
    expect(core.riskFund()).toEqual(0);
    expect(core.feesBurn()).toEqual(0);
    expect(core.feesReserve()).toEqual(0);
    expect(core.feesStaking()).toEqual(0);
}

get fun `test unknown opcode on core is rejected`() {
    val (core, deployer, _) = coreWith(1000000, false, 0, 0, false, 0, 0);
    val res = core.sendAny(deployer.address, beginCell().storeUint(0xDEAD, 32).endCell(), { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: deployer.address, to: core.address, exitCode: 65535 });
}

get fun `test LockBasePrices by non-owner is rejected`() {
    val (core, _, minter) = coreWith(1000000, false, 0, 0, false, 0, 0);
    val res = core.sendLockBasePrices(minter.address, 0, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: minter.address, to: core.address, exitCode: 101 });
}

get fun `test basket asset with negative weight is rejected`() {
    val (core, deployer, _) = coreWith(1000000, false, 0, 0, false, 0, 0);
    val res = core.sendSetBasketAsset(deployer.address, 0, 0, -1, 1000000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: deployer.address, to: core.address, exitCode: 107 });
}

get fun `test cam update with an out-of-range index is rejected`() {
    val (core, deployer, minter) = coreWith(1000000, false, 0, 0, false, 0, 0);
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    core.sendSetCam(deployer.address, 0, 0, minter.address, { value: ton("0.05") });
    val res = core.sendCamUpdate(minter.address, 0, 5, 1000000, 0, 1000000, 0, 1000, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: minter.address, to: core.address, exitCode: 109 });
}

get fun `test cam update with a stale timestamp is rejected`() {
    val (core, deployer, minter) = coreWith(1000000, false, 0, 0, false, 0, 0);
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    core.sendSetCam(deployer.address, 0, 0, minter.address, { value: ton("0.05") });
    core.sendCamUpdate(minter.address, 0, 0, 1000000, 0, 1000000, 0, 100, { value: ton("0.05") });
    val res = core.sendCamUpdate(minter.address, 0, 0, 1000000, 0, 1000000, 0, 100, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: minter.address, to: core.address, exitCode: 104 });
}

get fun `test oracle update with a stale timestamp is rejected`() {
    val (core, deployer, _) = coreWith(1000000, false, 0, 0, false, 0, 0);
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    core.sendOracleUpdateAssetPrice(deployer.address, 0, 0, 1100000, 1, { value: ton("0.05") });
    val res = core.sendOracleUpdateAssetPrice(deployer.address, 0, 0, 1100000, 1, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: deployer.address, to: core.address, exitCode: 104 });
}

get fun `test oracle update with a price jump is rejected`() {
    val (core, deployer, _) = coreWith(1000000, false, 0, 0, false, 0, 0);
    core.sendSetBasketAsset(deployer.address, 0, 0, 1000000, 1000000, { value: ton("0.05") });
    val res = core.sendOracleUpdateAssetPrice(deployer.address, 0, 0, 3000000, 1, { value: ton("0.05") });
    expect(res).toHaveFailedTx({ from: deployer.address, to: core.address, exitCode: 116 });
}
