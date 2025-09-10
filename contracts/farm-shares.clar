;; title: farm-shares
;; version: 1.0.0
;; summary: Tokenized Farm Shares NFT Contract
;; description: SIP-009 compliant NFT contract representing ownership shares in vertical farming operations

;; traits
;; SIP-009 compliant without external trait dependency

;; token definitions
(define-non-fungible-token farm-share uint)

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_OWNER_ONLY (err u100))
(define-constant ERR_NOT_TOKEN_OWNER (err u101))
(define-constant ERR_TOKEN_NOT_FOUND (err u102))
(define-constant ERR_CONTRACT_PAUSED (err u103))
(define-constant ERR_INVALID_RECIPIENT (err u104))
(define-constant ERR_INVALID_SHARE_DATA (err u105))
(define-constant ERR_MAX_SHARES_REACHED (err u106))
(define-constant ERR_SHARE_ALREADY_EXISTS (err u107))

(define-constant MAX_SHARES u10000)
(define-constant SHARE_PRECISION u1000000) ;; 6 decimal places for percentage calculations

;; data vars
(define-data-var contract-paused bool false)
(define-data-var last-token-id uint u0)
(define-data-var total-shares uint u0)
(define-data-var farm-operator principal CONTRACT_OWNER)
(define-data-var base-token-uri (string-ascii 256) "https://api.tokenized-farming.com/metadata/")

;; data maps
(define-map token-metadata uint {
    farm-id: (string-ascii 64),
    share-percentage: uint,
    investment-amount: uint,
    issue-date: uint,
    farm-location: (string-ascii 128),
    crop-type: (string-ascii 64)
})

(define-map shareholder-info principal {
    total-shares: uint,
    total-investment: uint,
    first-purchase-date: uint,
    total-claimed-rewards: uint
})

(define-map approved-operators principal bool)

;; public functions

;; SIP-009 required functions
(define-read-only (get-last-token-id)
    (ok (var-get last-token-id))
)

(define-read-only (get-token-uri (token-id uint))
    (ok (some (concat (var-get base-token-uri) (uint-to-ascii token-id))))
)

(define-read-only (get-owner (token-id uint))
    (ok (nft-get-owner? farm-share token-id))
)

(define-public (transfer (token-id uint) (sender principal) (recipient principal))
    (begin
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (is-eq tx-sender sender) ERR_NOT_TOKEN_OWNER)
        (asserts! (not (is-eq recipient sender)) ERR_INVALID_RECIPIENT)
        (try! (nft-transfer? farm-share token-id sender recipient))
        (print {event: "transfer", token-id: token-id, sender: sender, recipient: recipient})
        (ok true)
    )
)

;; Farm share management functions
(define-public (mint-farm-share 
    (recipient principal) 
    (farm-id (string-ascii 64))
    (share-percentage uint)
    (investment-amount uint)
    (farm-location (string-ascii 128))
    (crop-type (string-ascii 64))
)
    (let (
        (new-token-id (+ (var-get last-token-id) u1))
        (current-total-shares (var-get total-shares))
        (recipient-info (default-to {total-shares: u0, total-investment: u0, first-purchase-date: u0, total-claimed-rewards: u0}
                            (map-get? shareholder-info recipient)))
    )
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER) 
                     (is-eq tx-sender (var-get farm-operator))
                     (default-to false (map-get? approved-operators tx-sender))) ERR_OWNER_ONLY)
        (asserts! (<= new-token-id MAX_SHARES) ERR_MAX_SHARES_REACHED)
        (asserts! (> share-percentage u0) ERR_INVALID_SHARE_DATA)
        (asserts! (<= (+ current-total-shares share-percentage) SHARE_PRECISION) ERR_INVALID_SHARE_DATA)
        (asserts! (> investment-amount u0) ERR_INVALID_SHARE_DATA)
        
        (try! (nft-mint? farm-share new-token-id recipient))
        
        (map-set token-metadata new-token-id {
            farm-id: farm-id,
            share-percentage: share-percentage,
            investment-amount: investment-amount,
            issue-date: block-height,
            farm-location: farm-location,
            crop-type: crop-type
        })
        
        (map-set shareholder-info recipient {
            total-shares: (+ (get total-shares recipient-info) share-percentage),
            total-investment: (+ (get total-investment recipient-info) investment-amount),
            first-purchase-date: (if (is-eq (get first-purchase-date recipient-info) u0) 
                                    block-height 
                                    (get first-purchase-date recipient-info)),
            total-claimed-rewards: (get total-claimed-rewards recipient-info)
        })
        
        (var-set last-token-id new-token-id)
        (var-set total-shares (+ current-total-shares share-percentage))
        
        (print {event: "mint", token-id: new-token-id, recipient: recipient, share-percentage: share-percentage})
        (ok new-token-id)
    )
)

(define-public (burn-farm-share (token-id uint))
    (let (
        (token-owner (unwrap! (nft-get-owner? farm-share token-id) ERR_TOKEN_NOT_FOUND))
        (token-data (unwrap! (map-get? token-metadata token-id) ERR_TOKEN_NOT_FOUND))
        (owner-info (unwrap! (map-get? shareholder-info token-owner) ERR_TOKEN_NOT_FOUND))
    )
        (asserts! (not (var-get contract-paused)) ERR_CONTRACT_PAUSED)
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER)
                     (is-eq tx-sender (var-get farm-operator))
                     (is-eq tx-sender token-owner)) ERR_NOT_TOKEN_OWNER)
        
        (try! (nft-burn? farm-share token-id token-owner))
        
        (map-set shareholder-info token-owner {
            total-shares: (- (get total-shares owner-info) (get share-percentage token-data)),
            total-investment: (get total-investment owner-info),
            first-purchase-date: (get first-purchase-date owner-info),
            total-claimed-rewards: (get total-claimed-rewards owner-info)
        })
        
        (map-delete token-metadata token-id)
        (var-set total-shares (- (var-get total-shares) (get share-percentage token-data)))
        
        (print {event: "burn", token-id: token-id, owner: token-owner})
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

(define-public (approve-operator (operator principal) (approved bool))
    (begin
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER) (is-eq tx-sender (var-get farm-operator))) ERR_OWNER_ONLY)
        (map-set approved-operators operator approved)
        (print {event: "operator-approval", operator: operator, approved: approved})
        (ok true)
    )
)

(define-public (set-base-token-uri (new-uri (string-ascii 256)))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_OWNER_ONLY)
        (var-set base-token-uri new-uri)
        (print {event: "base-uri-updated", new-uri: new-uri})
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

(define-public (update-shareholder-rewards (shareholder principal) (additional-rewards uint))
    (let (
        (current-info (unwrap! (map-get? shareholder-info shareholder) ERR_INVALID_RECIPIENT))
    )
        (asserts! (or (is-eq tx-sender CONTRACT_OWNER) 
                     (is-eq tx-sender (var-get farm-operator))
                     (default-to false (map-get? approved-operators tx-sender))) ERR_OWNER_ONLY)
        
        (map-set shareholder-info shareholder {
            total-shares: (get total-shares current-info),
            total-investment: (get total-investment current-info),
            first-purchase-date: (get first-purchase-date current-info),
            total-claimed-rewards: (+ (get total-claimed-rewards current-info) additional-rewards)
        })
        
        (print {event: "rewards-updated", shareholder: shareholder, additional-rewards: additional-rewards})
        (ok true)
    )
)

;; read only functions
(define-read-only (get-token-metadata (token-id uint))
    (map-get? token-metadata token-id)
)

(define-read-only (get-shareholder-info (shareholder principal))
    (map-get? shareholder-info shareholder)
)

(define-read-only (get-total-shares)
    (var-get total-shares)
)

(define-read-only (get-farm-operator)
    (var-get farm-operator)
)

(define-read-only (is-contract-paused)
    (var-get contract-paused)
)

(define-read-only (is-operator-approved (operator principal))
    (default-to false (map-get? approved-operators operator))
)

(define-read-only (get-shareholder-percentage (shareholder principal))
    (let (
        (info (map-get? shareholder-info shareholder))
    )
        (match info
            some-info (some (get total-shares some-info))
            none
        )
    )
)

(define-read-only (calculate-share-value (token-id uint) (total-farm-value uint))
    (let (
        (metadata (map-get? token-metadata token-id))
    )
        (match metadata
            some-data (* total-farm-value (/ (get share-percentage some-data) SHARE_PRECISION))
            u0
        )
    )
)

;; private functions
(define-private (uint-to-ascii (value uint))
    (if (<= value u9)
        (unwrap-panic (element-at "0123456789" value))
        (get r (fold uint-to-ascii-fold 
                    (list u100000000 u10000000 u1000000 u100000 u10000 u1000 u100 u10 u1) 
                    {v: value, r: ""}))
    )
)

(define-private (uint-to-ascii-fold (i uint) (d {v: uint, r: (string-ascii 10)}))
    (if (>= (get v d) i)
        {v: (mod (get v d) i), r: (unwrap-panic (as-max-len? (concat (get r d) (unwrap-panic (element-at "0123456789" (/ (get v d) i)))) u10))}
        d
    )
)
