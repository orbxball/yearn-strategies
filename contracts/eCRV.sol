// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

interface IERC20Metadata {
    /**
     * @dev Returns the name of the token.
     */
    function name() external view returns (string memory);

    /**
     * @dev Returns the symbol of the token.
     */
    function symbol() external view returns (string memory);

    /**
     * @dev Returns the decimals places of the token.
     */
    function decimals() external view returns (uint8);
}

interface Uni {
    function swapExactTokensForTokens(
        uint256,
        uint256,
        address[] calldata,
        address,
        uint256
    ) external;

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ICurveFi {
    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount,
        bool _use_underlying
    ) external payable returns (uint256);

    function add_liquidity(
        uint256[3] calldata amounts,
        uint256 min_mint_amount,
        bool _use_underlying
    ) external payable returns (uint256);

    function add_liquidity(
        uint256[4] calldata amounts,
        uint256 min_mint_amount,
        bool _use_underlying
    ) external payable returns (uint256);

    function add_liquidity(
        uint256[2] calldata amounts,
        uint256 min_mint_amount
    ) external payable;

    function add_liquidity(
        uint256[3] calldata amounts,
        uint256 min_mint_amount
    ) external payable;

    function add_liquidity(
        uint256[4] calldata amounts,
        uint256 min_mint_amount
    ) external payable;

    // crv.finance: Curve.fi Factory USD Metapool v2
    function add_liquidity(
        address pool,
        uint256[4] calldata amounts,
        uint256 min_mint_amount
    ) external;

    function exchange(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external;

    function exchange_underlying(
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external;

    function get_dy(
        int128 i,
        int128 j,
        uint256 dx
    ) external view returns (uint256);

    function balances(int128) external view returns (uint256);

    function get_virtual_price() external view returns (uint256);
}

interface IVoterProxy {
    function withdraw(
        address _gauge,
        address _token,
        uint256 _amount
    ) external returns (uint256);
    function balanceOf(address _gauge) external view returns (uint256);
    function withdrawAll(address _gauge, address _token) external returns (uint256);
    function deposit(address _gauge, address _token) external;
    function harvest(address _gauge) external;
    function lock() external;
    function approveStrategy(address) external;
    function revokeStrategy(address) external;
}


abstract contract CurveVoterProxy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    address public constant voter = address(0xF147b8125d2ef93FB6965Db97D6746952a133934);

    address public constant crv = address(0xD533a949740bb3306d119CC777fa900bA034cd52);
    address public constant dai = address(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address public constant weth = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    address public constant wbtc = address(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    address public constant uniswap = address(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);
    address public constant sushiswap = address(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    uint256 public constant DENOMINATOR = 10000;

    address public proxy;
    address public dex;
    address public curve;
    address public gauge;
    uint256 public keepCRV;

    constructor(address _vault) public BaseStrategy(_vault) {
        minReportDelay = 6 hours;
        maxReportDelay = 2 days;
        profitFactor = 1000;
        debtThreshold = 1e24;
        proxy = address(0x9a165622a744C20E3B2CB443AeD98110a33a231b);
    }

    function setProxy(address _proxy) external onlyGovernance {
        proxy = _proxy;
    }

    function setKeepCRV(uint256 _keepCRV) external onlyGovernance {
        keepCRV = _keepCRV;
    }

    function switchDex(bool isUniswap) external onlyAuthorized {
        if (isUniswap) dex = uniswap;
        else dex = sushiswap;
    }

    function name() external view override returns (string memory) {
        return string(abi.encodePacked("Curve", IERC20Metadata(address(want)).symbol(), "VoterProxy"));
    }

    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function balanceOfPool() public view returns (uint256) {
        return IVoterProxy(proxy).balanceOf(gauge);
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(balanceOfPool());
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        uint256 _want = want.balanceOf(address(this));
        if (_want > 0) {
            want.safeTransfer(proxy, _want);
            IVoterProxy(proxy).deposit(gauge, address(want));
        }
    }

    function _withdrawSome(uint256 _amount) internal returns (uint256) {
        return IVoterProxy(proxy).withdraw(gauge, address(want), _amount);
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _balance = want.balanceOf(address(this));
        if (_balance < _amountNeeded) {
            _liquidatedAmount = _withdrawSome(_amountNeeded.sub(_balance));
            _liquidatedAmount = _liquidatedAmount.add(_balance);
            _loss = _amountNeeded.sub(_liquidatedAmount); // this should be 0. o/w there must be an error
        }
        else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function prepareMigration(address _newStrategy) internal override {
        IVoterProxy(proxy).withdrawAll(gauge, address(want));
    }

    function _adjustCRV(uint256 _crv) internal returns (uint256) {
        uint256 _keepCRV = _crv.mul(keepCRV).div(DENOMINATOR);
        IERC20(crv).safeTransfer(voter, _keepCRV);
        return _crv.sub(_keepCRV);
    }
}

contract Strategy is CurveVoterProxy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    constructor(address _vault) public CurveVoterProxy(_vault) {
        dex = sushiswap;
        curve = address(0xc5424B857f758E906013F3555Dad202e4bdB4567);
        gauge = address(0x3C0FFFF15EA30C35d7A85B85c0782D6c94e1d238);
        keepCRV = 1000;
    }

    receive() external payable {}

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        uint before = want.balanceOf(address(this));
        IVoterProxy(proxy).harvest(gauge);
        uint256 _crv = IERC20(crv).balanceOf(address(this));
        if (_crv > 0) {
            _crv = _adjustCRV(_crv);

            IERC20(crv).safeApprove(dex, 0);
            IERC20(crv).safeApprove(dex, _crv);

            address[] memory path = new address[](2);
            path[0] = crv;
            path[1] = weth;

            Uni(dex).swapExactTokensForETH(_crv, uint256(0), path, address(this), now);
        }
        uint256 _eth = address(this).balance;
        if (_eth > 0) {
            ICurveFi(curve).add_liquidity{value: _eth}([_eth, 0], 0);
        }
        _profit = want.balanceOf(address(this)).sub(before);

        uint _total = estimatedTotalAssets();
        uint _debt = vault.strategies(address(this)).totalDebt;
        if(_total < _debt) _loss = _debt - _total;

        uint _losss;
        if (_debtOutstanding > 0) {
            (_debtPayment, _losss) = liquidatePosition(_debtOutstanding);
        }
        _loss = _loss.add(_losss);
    }

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {
        address[] memory protected = new address[](1);
        protected[0] = crv;
        return protected;
    }
}
