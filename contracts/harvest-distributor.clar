;; title: harvest-distributor
;; version: 1.0.0
;; summary: Harvest Reward Distribution Contract
;; description: Automated distribution of harvest rewards to farm share token holders

;; traits
;; No traits needed - standalone contract

;; token definitions
;; No new tokens - manages STX distributions

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u200))
(define-constant ERR_INSUFFICIENT_FUNDS (err u201))
(define-constant ERR_ALREADY_CLAIMED (err u202))
(define-constant ERR_INVALID_CYCLE (err u203))
(define-constant ERR_CONTRACT_PAUSED (err u204))
(define-constant ERR_INVALID_RECIPIENT (err u205))
(define-constant ERR_INVALID_AMOUNT (err u206))
(define-constant ERR_CYCLE_NOT_READY (err u207))
(define-constant ERR_UNAUTHORIZED (err u208))
(define-constant ERR_INVALID_PERCENTAGE (err u209))

(define-constant PRECISION u1000000) ;; 6 decimal places
(define-constant MAX_REWARD_CYCLES u1000)
(define-constant MIN_CLAIM_DELAY u144) ;; ~24 hours in blocks

;; data vars
(define-data-var contract-paused bool false)
(define-data-var current-cycle uint u0)
(define-data-var total-deposited uint u0)
(define-data-var total-claimed uint u0)
(define-data-var farm-operator principal CONTRACT_OWNER)
(define-data-var emergency-withdrawal-enabled bool false)
(define-data-var min-share-threshold uint u1000) ;; Minimum shares to claim rewards

;; data maps
(define-map reward-cycles uint {
    total-rewards: uint,
    rewards-per-share: uint,
    cycle-start-block: uint,
    cycle-end-block: uint,
    claim-deadline: uint,
    total-shares-snapshot: uint,
    cycle-status: (string-ascii 16)
})

(define-map shareholder-claims {cycle: uint, shareholder: principal} {
    claimed-amount: uint,
    claim-block: uint,
    share-percentage: uint
})

(define-map shareholder-balances principal {
    total-claimed: uint,
    last-claim-cycle: uint,
    pending-rewards: uint,
    share-percentage: uint
})

(define-map cycle-participants uint (list 200 principal))

(define-map approved-distributors principal bool)

;; public functions

;; Admin functions for reward management
(define-public (deposit-harvest-rewards (cycle uint) (amount uint) (total-shares uint))
    (let (
        (existing-cycle (map-get? reward-cycles cycle))
        (rewards-per-share (if (> total-shares u0) (/ (* amount PRECISION) total-shares) u0))
    )
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER)
                     (is-eq tx-sender (var-get farm-operator))
                     (default-to false (map-get? approved-distributors tx-sender))) ERR_OWNER_ONLY)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        (asserts! (> total-shares u0) ERR_INVALID_PERCENTAGE)
        (asserts! (is-none existing-cycle) ERR_INVALID_CYCLE)
        
        ;; Transfer STX to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Record the reward cycle
        (map-set reward-cycles cycle {
            total-rewards: amount,
            rewards-per-share: rewards-per-share,
            cycle-start-block: block-height,
            cycle-end-block: (+ block-height MIN_CLAIM_DELAY),
            claim-deadline: (+ block-height (* MIN_CLAIM_DELAY u30)), ;; 30 day claim window
            total-shares-snapshot: total-shares,
            cycle-status: "active"
        })
        
        ;; Update contract state
        (var-set total-deposited (+ (var-get total-deposited) amount))
        (var-set current-cycle (max cycle (var-get current-cycle)))
        
        (print {event: "harvest-deposited", cycle: cycle, amount: amount, rewards-per-share: rewards-per-share})
        (ok cycle)
    )
)

(define-public (claim-rewards (cycle uint) (shareholder-percentage uint))
    (let (
        (cycle-info (unwrap! (map-get? reward-cycles cycle) ERR_INVALID_CYCLE))
        (claim-key {cycle: cycle, shareholder: tx-sender})
        (existing-claim (map-get? shareholder-claims claim-key))
        (rewards-amount (/ (* (get rewards-per-share cycle-info) shareholder-percentage) PRECISION))
        (current-balance (default-to {total-claimed: u0, last-claim-cycle: u0, pending-rewards: u0, share-percentage: u0}
                            (map-get? shareholder-balances tx-sender)))
    )
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (is-none existing-claim) ERR_ALREADY_CLAIMED)
        (asserts! (>= block-height (get cycle-end-block cycle-info)) ERR_CYCLE_NOT_READY)
        (asserts! (< block-height (get claim-deadline cycle-info)) ERR_CYCLE_NOT_READY)
        (asserts! (>= shareholder-percentage (var-get min-share-threshold)) ERR_INVALID_PERCENTAGE)
        (asserts! (> rewards-amount u0) ERR_INVALID_AMOUNT)
        (asserts! (is-eq (get cycle-status cycle-info) "active") ERR_INVALID_CYCLE)
        
        ;; Record the claim
        (map-set shareholder-claims claim-key {
            claimed-amount: rewards-amount,
            claim-block: block-height,
            share-percentage: shareholder-percentage
        })
        
        ;; Update shareholder balance
        (map-set shareholder-balances tx-sender {
            total-claimed: (+ (get total-claimed current-balance) rewards-amount),
            last-claim-cycle: cycle,
            pending-rewards: u0,
            share-percentage: shareholder-percentage
        })
        
        ;; Transfer rewards to shareholder
        (try! (as-contract (stx-transfer? rewards-amount tx-sender tx-sender)))
        
        ;; Update global state
        (var-set total-claimed (+ (var-get total-claimed) rewards-amount))
        
        (print {event: "rewards-claimed", cycle: cycle, shareholder: tx-sender, amount: rewards-amount})
        (ok rewards-amount)
    )
)

(define-public (batch-claim-rewards (cycles (list 10 uint)) (shareholder-percentage uint))
    (let (
        (claim-results (map claim-single-cycle cycles))
    )
        (ok claim-results)
    )
)

(define-public (finalize-cycle (cycle uint))
    (let (
        (cycle-info (unwrap! (map-get? reward-cycles cycle) ERR_INVALID_CYCLE))
    )
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER)
                     (is-eq tx-sender (var-get farm-operator))) ERR_OWNER_ONLY)
        (asserts! (> block-height (get claim-deadline cycle-info)) ERR_CYCLE_NOT_READY)
        
        ;; Update cycle status to closed
        (map-set reward-cycles cycle 
            (merge cycle-info {cycle-status: "closed"}))
        
        (print {event: "cycle-finalized", cycle: cycle})
        (ok true)
    )
)

;; Administrative functions
(define-public (set-farm-operator (new-operator principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        (var-set farm-operator new-operator)
        (print {event: "farm-operator-updated", new-operator: new-operator})
        (ok true)
    )
)

(define-public (approve-distributor (distributor principal) (approved bool))
    (begin
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER) (is-eq tx-sender (var-get farm-operator))) ERR_OWNER_ONLY)
        (map-set approved-distributors distributor approved)
        (print {event: "distributor-approval", distributor: distributor, approved: approved})
        (ok true)
    )
)

(define-public (pause-contract)
    (begin
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER) (is-eq tx-sender (var-get farm-operator))) ERR_OWNER_ONLY)
        (var-set contract-paused true)
        (print {event: "contract-paused"})
        (ok true)
    )
)

(define-public (unpause-contract)
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        (var-set contract-paused false)
        (print {event: "contract-unpaused"})
        (ok true)
    )
)

(define-public (set-min-share-threshold (threshold uint))
    (begin
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER) (is-eq tx-sender (var-get farm-operator))) ERR_OWNER_ONLY)
        (var-set min-share-threshold threshold)
        (print {event: "threshold-updated", threshold: threshold})
        (ok true)
    )
)

(define-public (enable-emergency-withdrawal)
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        (var-set emergency-withdrawal-enabled true)
        (print {event: "emergency-withdrawal-enabled"})
        (ok true)
    )
)

(define-public (emergency-withdraw (amount uint) (recipient principal))
    (begin
        (asserts! (var-get emergency-withdrawal-enabled) ERR_UNAUTHORIZED)
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        
        (try! (as-contract (stx-transfer? amount tx-sender recipient)))
        
        (print {event: "emergency-withdrawal", amount: amount, recipient: recipient})
        (ok true)
    )
)

;; read only functions
(define-read-only (get-reward-cycle (cycle uint))
    (map-get? reward-cycles cycle)
)

(define-read-only (get-shareholder-claim (cycle uint) (shareholder principal))
    (map-get? shareholder-claims {cycle: cycle, shareholder: shareholder})
)

(define-read-only (get-shareholder-balance (shareholder principal))
    (map-get? shareholder-balances shareholder)
)

(define-read-only (get-current-cycle)
    (var-get current-cycle)
)

(define-read-only (get-contract-balance)
    (stx-get-balance (as-contract tx-sender))
)

(define-read-only (get-total-deposited)
    (var-get total-deposited)
)

(define-read-only (get-total-claimed)
    (var-get total-claimed)
)

(define-read-only (is-contract-paused)
    (var-get contract-paused)
)

(define-read-only (get-farm-operator)
    (var-get farm-operator)
)

(define-read-only (calculate-pending-rewards (shareholder principal) (current-share-percentage uint))
    (let (
        (balance-info (map-get? shareholder-balances shareholder))
        (last-claimed-cycle (match balance-info some-info (get last-claim-cycle some-info) u0))
    )
        (fold calculate-cycle-rewards 
              (list (+ last-claimed-cycle u1) (+ last-claimed-cycle u2) (+ last-claimed-cycle u3) (+ last-claimed-cycle u4) (+ last-claimed-cycle u5))
              {shareholder: shareholder, total-pending: u0, share-percentage: current-share-percentage})
    )
)

(define-read-only (get-claimable-cycles (shareholder principal))
    (let (
        (balance-info (map-get? shareholder-balances shareholder))
        (last-claimed (match balance-info some-info (get last-claim-cycle some-info) u0))
        (current (var-get current-cycle))
    )
        (if (<= current last-claimed)
            (list)
            (generate-cycle-list (+ last-claimed u1) current)
        )
    )
)

(define-read-only (is-distributor-approved (distributor principal))
    (default-to false (map-get? approved-distributors distributor))
)

;; private functions
(define-private (claim-single-cycle (cycle uint))
    (let (
        (balance-info (default-to {total-claimed: u0, last-claim-cycle: u0, pending-rewards: u0, share-percentage: u0}
                         (map-get? shareholder-balances tx-sender)))
    )
        (claim-rewards cycle (get share-percentage balance-info))
    )
)

(define-private (calculate-cycle-rewards (cycle uint) (acc {shareholder: principal, total-pending: uint, share-percentage: uint}))
    (let (
        (cycle-info (map-get? reward-cycles cycle))
        (claim-key {cycle: cycle, shareholder: (get shareholder acc)})
        (already-claimed (map-get? shareholder-claims claim-key))
    )
        (match cycle-info
            some-cycle-data 
                (if (and (is-none already-claimed) 
                        (is-eq (get cycle-status some-cycle-data) "active")
                        (>= block-height (get cycle-end-block some-cycle-data))
                        (< block-height (get claim-deadline some-cycle-data)))
                    {shareholder: (get shareholder acc),
                     total-pending: (+ (get total-pending acc) 
                                     (/ (* (get rewards-per-share some-cycle-data) (get share-percentage acc)) PRECISION)),
                     share-percentage: (get share-percentage acc)}
                    acc
                )
            acc
        )
    )
)

(define-private (generate-cycle-list (start uint) (end uint))
    (if (> start end)
        (list)
        (unwrap-panic (as-max-len? 
            (append (generate-cycle-list (+ start u1) end) start)
            u10
        ))
    )
)
