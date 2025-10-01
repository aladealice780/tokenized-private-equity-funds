;; =============================================================================
;; PE TOKENIZER - PRIVATE EQUITY FUND TOKENIZATION PLATFORM
;; =============================================================================
;; Tokenize private equity fund shares
;; Enable fractional PE fund ownership
;; Facilitate secondary market trading
;; Distribute fund returns and carried interest
;; Manage investor accreditation and compliance

;; =============================================================================
;; ERROR CODES
;; =============================================================================

(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_FUND_NOT_FOUND (err u101))
(define-constant ERR_INSUFFICIENT_BALANCE (err u102))
(define-constant ERR_INVALID_AMOUNT (err u103))
(define-constant ERR_NOT_ACCREDITED (err u104))
(define-constant ERR_TRANSFER_RESTRICTED (err u105))
(define-constant ERR_INVALID_RECIPIENT (err u106))
(define-constant ERR_FUND_CLOSED (err u107))
(define-constant ERR_MINIMUM_NOT_MET (err u108))
(define-constant ERR_ALREADY_INVESTOR (err u109))
(define-constant ERR_DISTRIBUTION_ERROR (err u110))
(define-constant ERR_GOVERNANCE_ERROR (err u111))

;; =============================================================================
;; CONSTANTS
;; =============================================================================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant MINIMUM_INVESTMENT u10000000000) ;; 10,000 STX (vs traditional $1M minimum)
(define-constant MANAGEMENT_FEE_RATE u200) ;; 2% annual management fee (basis points)
(define-constant CARRIED_INTEREST_RATE u2000) ;; 20% carried interest (basis points)
(define-constant PRECISION u10000) ;; 100.00% = 10000
(define-constant HURDLE_RATE u800) ;; 8% hurdle rate for carried interest
(define-constant BLOCKS_PER_YEAR u52560) ;; Approximate blocks per year
(define-constant MAX_INVESTORS_PER_FUND u500) ;; Regulatory limit for number of investors

;; =============================================================================
;; DATA STRUCTURES
;; =============================================================================

;; Private Equity Fund Information
(define-map pe-funds
  { fund-id: uint }
  {
    name: (string-ascii 128),
    fund-manager: principal,
    strategy: (string-ascii 64), ;; "Growth", "Buyout", "Venture", etc.
    target-size: uint, ;; Target fund size in STX
    commitment-period: uint, ;; Block height when commitment period ends
    fund-life: uint, ;; Fund life in blocks (typically 10 years)
    management-fee: uint, ;; Annual management fee (basis points)
    carried-interest: uint, ;; Carried interest percentage (basis points)
    hurdle-rate: uint, ;; Minimum return before carried interest (basis points)
    total-committed: uint, ;; Total commitments from all investors
    total-called: uint, ;; Total capital called from investors
    total-distributed: uint, ;; Total distributions paid to investors
    nav: uint, ;; Current Net Asset Value
    created-at: uint, ;; Block height when fund was created
    status: (string-ascii 16), ;; "Active", "Closed", "Liquidating"
    investor-count: uint,
    minimum-commitment: uint
  }
)

;; Investor commitments and holdings
(define-map investor-positions
  { fund-id: uint, investor: principal }
  {
    commitment-amount: uint, ;; Total commitment to fund
    called-amount: uint, ;; Amount actually called/invested
    token-balance: uint, ;; Current token balance
    distributions-received: uint, ;; Total distributions received
    commitment-date: uint, ;; When investor committed
    accredited-verified: bool, ;; KYC/accreditation status
    transfer-restricted: bool ;; Whether tokens can be transferred
  }
)

;; Fund token supply tracking
(define-map fund-tokens
  { fund-id: uint }
  {
    total-supply: uint,
    tokens-outstanding: uint,
    token-price: uint, ;; Current price per token (NAV basis)
    last-valuation-date: uint
  }
)

;; Secondary market trading orders
(define-map trading-orders
  { order-id: uint }
  {
    fund-id: uint,
    seller: principal,
    buyer: (optional principal),
    token-amount: uint,
    price-per-token: uint,
    order-type: (string-ascii 16), ;; "Buy" or "Sell"
    status: (string-ascii 16), ;; "Open", "Filled", "Cancelled"
    created-at: uint,
    expires-at: uint
  }
)

;; Distribution waterfall tracking
(define-map fund-distributions
  { fund-id: uint, distribution-id: uint }
  {
    total-amount: uint,
    distribution-date: uint,
    return-of-capital: uint, ;; Amount that is return of capital
    capital-gain: uint, ;; Amount that is capital gain
    carried-interest-paid: uint, ;; Carried interest paid to GP
    management-fees-paid: uint, ;; Management fees paid
    distribution-per-token: uint
  }
)

;; Accredited investor registry
(define-map accredited-investors
  { investor: principal }
  {
    verified-date: uint,
    verification-method: (string-ascii 32),
    expiry-date: uint,
    net-worth: uint,
    annual-income: uint,
    institutional: bool
  }
)

;; Governance voting records
(define-map governance-votes
  { fund-id: uint, proposal-id: uint, voter: principal }
  {
    vote: (string-ascii 8), ;; "For", "Against", "Abstain"
    voting-power: uint, ;; Token balance at time of vote
    vote-date: uint
  }
)

;; =============================================================================
;; DATA VARIABLES
;; =============================================================================

(define-data-var next-fund-id uint u1)
(define-data-var next-order-id uint u1)
(define-data-var next-distribution-id uint u1)
(define-data-var next-proposal-id uint u1)
(define-data-var total-funds-created uint u0)
(define-data-var total-aum uint u0) ;; Total assets under management
(define-data-var platform-fees-collected uint u0)
(define-data-var compliance-officer (optional principal) none)
(define-data-var emergency-shutdown bool false)

;; =============================================================================
;; PRIVATE FUNCTIONS
;; =============================================================================

;; Calculate token price based on NAV
(define-private (calculate-token-price (fund-id uint))
  (match (map-get? pe-funds { fund-id: fund-id })
    fund
    (match (map-get? fund-tokens { fund-id: fund-id })
      tokens
      (if (> (get tokens-outstanding tokens) u0)
        (/ (get nav fund) (get tokens-outstanding tokens))
        u0)
      u0)
    u0
  )
)

;; Calculate management fees owed
(define-private (calculate-management-fees (fund-id uint) (commitment-amount uint) (blocks-elapsed uint))
  (let (
    (annual-fee-rate (unwrap! (get management-fee (map-get? pe-funds { fund-id: fund-id })) u0))
    (annual-fee (/ (* commitment-amount annual-fee-rate) PRECISION))
    (blocks-per-year BLOCKS_PER_YEAR)
  )
    (/ (* annual-fee blocks-elapsed) blocks-per-year)
  )
)

;; Calculate carried interest for distribution
(define-private (calculate-carried-interest (fund-id uint) (total-gains uint))
  (match (map-get? pe-funds { fund-id: fund-id })
    fund
    (let (
      (hurdle-amount (/ (* (get total-called fund) (get hurdle-rate fund)) PRECISION))
      (excess-return (if (> total-gains hurdle-amount) (- total-gains hurdle-amount) u0))
    )
      (/ (* excess-return (get carried-interest fund)) PRECISION)
    )
    u0
  )
)

;; Validate investor accreditation
(define-private (validate-accreditation (investor principal))
  (match (map-get? accredited-investors { investor: investor })
    accred-info
    (and 
      (get institutional accred-info)
      (> (get expiry-date accred-info) stacks-block-height)
    )
    false
  )
)

;; Update fund NAV based on portfolio performance
(define-private (update-fund-nav (fund-id uint) (new-nav uint))
  (match (map-get? pe-funds { fund-id: fund-id })
    fund
    (match (map-get? fund-tokens { fund-id: fund-id })
      tokens
      (begin
        (map-set pe-funds
          { fund-id: fund-id }
          (merge fund { nav: new-nav })
        )
        (map-set fund-tokens
          { fund-id: fund-id }
          (merge tokens { 
            token-price: (calculate-token-price fund-id),
            last-valuation-date: stacks-block-height 
          })
        )
        (ok true)
      )
      ERR_FUND_NOT_FOUND
    )
    ERR_FUND_NOT_FOUND
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS - ADMIN
;; =============================================================================

;; Create a new private equity fund
(define-public (create-fund
  (name (string-ascii 128))
  (strategy (string-ascii 64))
  (target-size uint)
  (fund-life-years uint)
  (management-fee uint)
  (carried-interest uint)
  (hurdle-rate uint)
  (minimum-commitment uint)
)
  (let (
    (fund-id (var-get next-fund-id))
    (fund-life-blocks (* fund-life-years BLOCKS_PER_YEAR))
    (commitment-period (+ stacks-block-height (* u2 BLOCKS_PER_YEAR))) ;; 2 year commitment period
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> target-size u0) ERR_INVALID_AMOUNT)
    (asserts! (and (>= management-fee u0) (<= management-fee u500)) ERR_INVALID_AMOUNT) ;; Max 5% mgmt fee
    (asserts! (and (>= carried-interest u0) (<= carried-interest u3000)) ERR_INVALID_AMOUNT) ;; Max 30% carry
    
    ;; Create fund record
    (map-set pe-funds
      { fund-id: fund-id }
      {
        name: name,
        fund-manager: tx-sender,
        strategy: strategy,
        target-size: target-size,
        commitment-period: commitment-period,
        fund-life: fund-life-blocks,
        management-fee: management-fee,
        carried-interest: carried-interest,
        hurdle-rate: hurdle-rate,
        total-committed: u0,
        total-called: u0,
        total-distributed: u0,
        nav: u0,
        created-at: stacks-block-height,
        status: "Active",
        investor-count: u0,
        minimum-commitment: minimum-commitment
      }
    )
    
    ;; Initialize token tracking
    (map-set fund-tokens
      { fund-id: fund-id }
      {
        total-supply: u0,
        tokens-outstanding: u0,
        token-price: u1000000, ;; Initial price: 1 STX per token
        last-valuation-date: stacks-block-height
      }
    )
    
    ;; Update global counters
    (var-set next-fund-id (+ fund-id u1))
    (var-set total-funds-created (+ (var-get total-funds-created) u1))
    
    (ok fund-id)
  )
)

;; Register an accredited investor
(define-public (register-accredited-investor
  (investor principal)
  (net-worth uint)
  (annual-income uint)
  (institutional bool)
  (verification-method (string-ascii 32))
)
  (begin
    (asserts! (or (is-eq tx-sender CONTRACT_OWNER)
                 (is-eq (some tx-sender) (var-get compliance-officer))) ERR_UNAUTHORIZED)
    
    (map-set accredited-investors
      { investor: investor }
      {
        verified-date: stacks-block-height,
        verification-method: verification-method,
        expiry-date: (+ stacks-block-height (* u3 BLOCKS_PER_YEAR)), ;; Valid for 3 years
        net-worth: net-worth,
        annual-income: annual-income,
        institutional: institutional
      }
    )
    
    (ok true)
  )
)

;; Update fund NAV (for fund manager)
(define-public (update-nav (fund-id uint) (new-nav uint))
  (match (map-get? pe-funds { fund-id: fund-id })
    fund
    (begin
      (asserts! (is-eq tx-sender (get fund-manager fund)) ERR_UNAUTHORIZED)
      (asserts! (> new-nav u0) ERR_INVALID_AMOUNT)
      (try! (update-fund-nav fund-id new-nav))
      (ok new-nav)
    )
    ERR_FUND_NOT_FOUND
  )
)

;; =============================================================================
;; PUBLIC FUNCTIONS - INVESTOR FUNCTIONS
;; =============================================================================

;; Commit capital to a fund
(define-public (commit-to-fund (fund-id uint) (commitment-amount uint))
  (let (
    (fund (unwrap! (map-get? pe-funds { fund-id: fund-id }) ERR_FUND_NOT_FOUND))
    (existing-position (map-get? investor-positions { fund-id: fund-id, investor: tx-sender }))
  )
    ;; Validation checks
    (asserts! (not (var-get emergency-shutdown)) ERR_UNAUTHORIZED)
    (asserts! (validate-accreditation tx-sender) ERR_NOT_ACCREDITED)
    (asserts! (is-eq (get status fund) "Active") ERR_FUND_CLOSED)
    (asserts! (>= commitment-amount (get minimum-commitment fund)) ERR_MINIMUM_NOT_MET)
    (asserts! (< stacks-block-height (get commitment-period fund)) ERR_FUND_CLOSED)
    (asserts! (is-none existing-position) ERR_ALREADY_INVESTOR)
    (asserts! (< (get investor-count fund) MAX_INVESTORS_PER_FUND) ERR_INVALID_RECIPIENT)
    
    ;; Calculate tokens to issue (1:1 ratio initially)
    (let ((tokens-to-issue commitment-amount))
      
      ;; Create investor position
      (map-set investor-positions
        { fund-id: fund-id, investor: tx-sender }
        {
          commitment-amount: commitment-amount,
          called-amount: u0,
          token-balance: tokens-to-issue,
          distributions-received: u0,
          commitment-date: stacks-block-height,
          accredited-verified: true,
          transfer-restricted: false
        }
      )
      
      ;; Update fund totals
      (map-set pe-funds
        { fund-id: fund-id }
        (merge fund {
          total-committed: (+ (get total-committed fund) commitment-amount),
          investor-count: (+ (get investor-count fund) u1)
        })
      )
      
      ;; Update token supply
      (match (map-get? fund-tokens { fund-id: fund-id })
        tokens
        (begin
          (map-set fund-tokens
            { fund-id: fund-id }
            (merge tokens {
              total-supply: (+ (get total-supply tokens) tokens-to-issue),
              tokens-outstanding: (+ (get tokens-outstanding tokens) tokens-to-issue)
            })
          )
          true
        )
        false
      )
      
      ;; Update global AUM
      (var-set total-aum (+ (var-get total-aum) commitment-amount))
      
      (ok tokens-to-issue)
    )
  )
)

;; Transfer tokens (secondary market)
(define-public (transfer-tokens (fund-id uint) (recipient principal) (amount uint))
  (let (
    (sender-position (unwrap! (map-get? investor-positions { fund-id: fund-id, investor: tx-sender }) ERR_INSUFFICIENT_BALANCE))
    (recipient-position (map-get? investor-positions { fund-id: fund-id, investor: recipient }))
  )
    ;; Validation checks
    (asserts! (validate-accreditation recipient) ERR_NOT_ACCREDITED)
    (asserts! (not (get transfer-restricted sender-position)) ERR_TRANSFER_RESTRICTED)
    (asserts! (>= (get token-balance sender-position) amount) ERR_INSUFFICIENT_BALANCE)
    (asserts! (> amount u0) ERR_INVALID_AMOUNT)
    
    ;; Update sender position
    (map-set investor-positions
      { fund-id: fund-id, investor: tx-sender }
      (merge sender-position {
        token-balance: (- (get token-balance sender-position) amount)
      })
    )
    
    ;; Update or create recipient position
    (match recipient-position
      existing-pos
      ;; Update existing position
      (map-set investor-positions
        { fund-id: fund-id, investor: recipient }
        (merge existing-pos {
          token-balance: (+ (get token-balance existing-pos) amount)
        })
      )
      ;; Create new position for recipient
      (map-set investor-positions
        { fund-id: fund-id, investor: recipient }
        {
          commitment-amount: u0,
          called-amount: u0,
          token-balance: amount,
          distributions-received: u0,
          commitment-date: stacks-block-height,
          accredited-verified: true,
          transfer-restricted: false
        }
      )
    )
    
    (ok amount)
  )
)

;; Claim distribution
(define-public (claim-distribution (fund-id uint) (distribution-id uint))
  (let (
    (position (unwrap! (map-get? investor-positions { fund-id: fund-id, investor: tx-sender }) ERR_UNAUTHORIZED))
    (distribution (unwrap! (map-get? fund-distributions { fund-id: fund-id, distribution-id: distribution-id }) ERR_DISTRIBUTION_ERROR))
    (distribution-amount (* (get token-balance position) (get distribution-per-token distribution)))
  )
    (asserts! (> distribution-amount u0) ERR_INVALID_AMOUNT)
    
    ;; Transfer distribution to investor
    (try! (stx-transfer? distribution-amount (as-contract tx-sender) tx-sender))
    
    ;; Update position with distribution received
    (map-set investor-positions
      { fund-id: fund-id, investor: tx-sender }
      (merge position {
        distributions-received: (+ (get distributions-received position) distribution-amount)
      })
    )
    
    (ok distribution-amount)
  )
)

;; =============================================================================
;; READ-ONLY FUNCTIONS
;; =============================================================================

;; Get fund information
(define-read-only (get-fund (fund-id uint))
  (map-get? pe-funds { fund-id: fund-id })
)

;; Get investor position
(define-read-only (get-position (fund-id uint) (investor principal))
  (map-get? investor-positions { fund-id: fund-id, investor: investor })
)

;; Get fund tokens info
(define-read-only (get-fund-tokens (fund-id uint))
  (map-get? fund-tokens { fund-id: fund-id })
)

;; Check accreditation status
(define-read-only (is-accredited (investor principal))
  (validate-accreditation investor)
)

;; Get current token price
(define-read-only (get-token-price (fund-id uint))
  (calculate-token-price fund-id)
)

;; Get platform statistics
(define-read-only (get-platform-stats)
  (ok {
    total-funds: (var-get total-funds-created),
    total-aum: (var-get total-aum),
    platform-fees: (var-get platform-fees-collected),
    next-fund-id: (var-get next-fund-id)
  })
)

;; Calculate investor returns
(define-read-only (calculate-returns (fund-id uint) (investor principal))
  (match (map-get? investor-positions { fund-id: fund-id, investor: investor })
    position
    (let (
      (current-value (* (get token-balance position) (calculate-token-price fund-id)))
      (total-invested (get called-amount position))
      (total-received (get distributions-received position))
      (total-return (+ current-value total-received))
      (net-return (if (> total-invested u0) (- total-return total-invested) u0))
    )
      (ok {
        current-value: current-value,
        total-invested: total-invested,
        total-received: total-received,
        total-return: total-return,
        net-return: net-return,
        return-multiple: (if (> total-invested u0) (/ total-return total-invested) u0)
      })
    )
    ERR_UNAUTHORIZED
  )
)
