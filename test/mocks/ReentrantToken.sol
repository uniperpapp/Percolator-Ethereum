// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IPerpMarket {
    function deposit(uint256 positionId, uint256 amount) external returns (uint256);
    function withdraw(uint256 positionId, uint256 amount, address to) external;
}

/// @notice A malicious ERC-20 that is ALSO the position owner. On the withdraw payout
///         transfer (market -> this), its transfer hook re-enters `withdraw`. Because
///         the token owns the position, the re-entrant call passes authorization and
///         therefore actually exercises the `nonReentrant` guard (not the owner check).
///         A correct market blocks the inner call and pays out exactly once.
contract ReentrantToken {
    string public name = "Reenter";
    string public symbol = "RENT";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    IPerpMarket public market;
    uint256 public positionId;
    bool public armed;
    bool public reentryWasBlocked;
    bool public reentryFired;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    /// @notice Deposit `amount` (token is the owner), then withdraw it — the payout
    ///         transfer triggers the re-entrancy attempt inside `_transfer`.
    function runAttack(address market_, uint256 amount) external {
        market = IPerpMarket(market_);
        mint(address(this), amount);
        approve(market_, amount);
        positionId = market.deposit(0, amount);
        armed = true;
        market.withdraw(positionId, amount, address(this));
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);

        // Re-enter on the way OUT of the market (the withdraw payout).
        if (armed && from == address(market)) {
            armed = false; // one-shot
            reentryFired = true;
            try market.withdraw(positionId, 1, address(this)) {
                reentryWasBlocked = false;
            } catch {
                reentryWasBlocked = true;
            }
        }
    }
}
