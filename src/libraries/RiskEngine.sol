// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Constants} from "./Constants.sol";
import {FixedPointMath} from "./FixedPointMath.sol";
import {Types} from "./Types.sol";

/// @title RiskEngine
/// @notice The chain-agnostic safety core: the master conservation invariant,
///         the H haircut (positive PnL is a JUNIOR claim on Residual), risk
///         notional, and margin requirements. Faithful port of Percolator
///         spec.md §3 and §7.
///
/// @dev IMPLEMENTED in this milestone: residual/conservation, haircut ratio H,
///      effective matured PnL, risk notional (ceil), maintenance/initial margin.
///      NEXT milestones (see docs/DESIGN.md): lazy A/K/F accrual & per-account
///      settlement (§5), warmup/admission (§4.3), liquidation + ADL (§5.4/§7),
///      and the §1.6 per-risk-notional solvency proof re-derived in seconds.
library RiskEngine {
    using FixedPointMath for uint256;

    error ConservationViolated(uint256 vault, uint256 cTot, uint256 insurance);

    /// @notice Residual = V - (C_tot + I): the pool of value backing JUNIOR positive PnL.
    ///         Reverts if the master invariant V >= C_tot + I is broken.
    function residual(uint256 vault, uint256 cTot, uint256 insurance)
        internal
        pure
        returns (uint256)
    {
        uint256 senior = cTot + insurance;
        if (vault < senior) revert ConservationViolated(vault, cTot, insurance);
        return vault - senior;
    }

    /// @notice The master invariant. MUST hold at the end of every state-mutating op.
    function assertConservation(uint256 vault, uint256 cTot, uint256 insurance) internal pure {
        if (vault < cTot + insurance) revert ConservationViolated(vault, cTot, insurance);
    }

    /// @notice Haircut ratio h = min(Residual, maturedPosTot) / maturedPosTot as (num, den).
    ///         h = (1,1) when there is no matured positive PnL. h in [0,1].
    function haircutRatio(uint256 residual_, uint256 maturedPosTot)
        internal
        pure
        returns (Types.Ratio memory h)
    {
        if (maturedPosTot == 0) return Types.Ratio({num: 1, den: 1});
        h.num = residual_ < maturedPosTot ? residual_ : maturedPosTot;
        h.den = maturedPosTot;
    }

    /// @notice Effective (haircut) matured PnL for one account:
    ///         floor(released * h.num / h.den). Floor is conservative (favors vault).
    function effectiveMaturedPnl(uint256 released, uint256 residual_, uint256 maturedPosTot)
        internal
        pure
        returns (uint256)
    {
        Types.Ratio memory h = haircutRatio(residual_, maturedPosTot);
        if (h.num == h.den) return released; // h == 1 fast path
        return FixedPointMath.mulDivDown(released, h.num, h.den);
    }

    /// @notice Risk notional uses CEIL so fractional-notional dust still carries margin:
    ///         ceil(|effPosQ| * oraclePrice / POS_SCALE). Spec §1.2 "load-bearing ceiling".
    function riskNotional(uint256 effPosAbsQ, uint256 oraclePrice) internal pure returns (uint256) {
        if (effPosAbsQ == 0) return 0;
        return FixedPointMath.mulDivUp(effPosAbsQ, oraclePrice, Constants.POS_SCALE);
    }

    /// @notice Maintenance margin = max(floor(rn * maintBps / 10_000), minNonzeroMm); 0 if flat.
    function maintenanceReq(uint256 riskNotional_, uint256 maintBps, uint256 minNonzeroMm)
        internal
        pure
        returns (uint256)
    {
        if (riskNotional_ == 0) return 0;
        uint256 r = FixedPointMath.mulDivDown(riskNotional_, maintBps, Constants.BPS_DENOM);
        return r > minNonzeroMm ? r : minNonzeroMm;
    }

    /// @notice Initial margin = max(floor(rn * initialBps / 10_000), minNonzeroIm); 0 if flat.
    function initialReq(uint256 riskNotional_, uint256 initialBps, uint256 minNonzeroIm)
        internal
        pure
        returns (uint256)
    {
        if (riskNotional_ == 0) return 0;
        uint256 r = FixedPointMath.mulDivDown(riskNotional_, initialBps, Constants.BPS_DENOM);
        return r > minNonzeroIm ? r : minNonzeroIm;
    }

    // ---------------------------------------------------------------------
    // Equity lanes (spec §3). All exact in int256.
    //   FeeDebt_i        = -min(feeCredits_i, 0)            (>= 0)
    //   ReleasedPos_i    = max(PNL_i,0) - R_i               (Live)
    //   Eq_withdraw_raw  = C_i + min(PNL_i,0) + PNL_eff_matured_i - FeeDebt_i
    //   Eq_maint_raw     = C_i + PNL_i - FeeDebt_i
    //   Eq_net           = max(0, Eq_maint_raw)
    // The withdraw lane credits only HAIRCUT MATURED PnL; the maintenance lane uses
    // raw full PnL — the asymmetry that lets unrealized gains support margin but not
    // be withdrawn until they mature and the haircut releases them.
    // ---------------------------------------------------------------------

    /// @notice FeeDebt_i = -min(feeCredits_i, 0). feeCredits is always <= 0.
    function feeDebt(int256 feeCredits) internal pure returns (uint256) {
        return feeCredits < 0 ? uint256(-feeCredits) : 0;
    }

    /// @notice ReleasedPos_i = max(PNL_i,0) - R_i (Live). Reverts implicitly if the
    ///         live reserve invariant R_i <= max(PNL_i,0) is broken (caller-enforced).
    function releasedPos(int256 pnl, uint256 reservedPnl) internal pure returns (uint256) {
        uint256 posPnl = pnl > 0 ? uint256(pnl) : 0;
        return posPnl - reservedPnl; // underflow-guarded by Solidity 0.8 checked math
    }

    /// @notice Withdrawal-lane equity: C_i + min(PNL_i,0) + haircut(matured) - FeeDebt_i.
    function withdrawEquity(
        uint256 capital,
        int256 pnl,
        uint256 reservedPnl,
        int256 feeCredits,
        uint256 residual_,
        uint256 maturedPosTot
    ) internal pure returns (int256) {
        uint256 effMatured = effectiveMaturedPnl(
            releasedPos(pnl, reservedPnl), residual_, maturedPosTot
        );
        int256 negPnl = pnl < 0 ? pnl : int256(0);
        return int256(capital) + negPnl + int256(effMatured) - int256(feeDebt(feeCredits));
    }

    /// @notice Maintenance-lane equity (raw, may be negative): C_i + PNL_i - FeeDebt_i.
    function maintenanceEquity(uint256 capital, int256 pnl, int256 feeCredits)
        internal
        pure
        returns (int256)
    {
        return int256(capital) + pnl - int256(feeDebt(feeCredits));
    }

    /// @notice Eq_net_i = max(0, Eq_maint_raw_i).
    function netEquity(uint256 capital, int256 pnl, int256 feeCredits)
        internal
        pure
        returns (uint256)
    {
        int256 e = maintenanceEquity(capital, pnl, feeCredits);
        return e > 0 ? uint256(e) : 0;
    }
}
