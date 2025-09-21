;; Community Childcare Network - Caregiver Certification Contract
;; Verify and certify community childcare providers with background checks and skill tracking

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-found (err u101))
(define-constant err-already-exists (err u102))
(define-constant err-invalid-status (err u103))
(define-constant err-expired-certification (err u104))
(define-constant err-insufficient-score (err u105))

;; Data Variables
(define-data-var next-caregiver-id uint u1)
(define-data-var certification-fee uint u1000000) ;; 1 STX in microSTX
(define-data-var minimum-safety-score uint u70)

;; Data Maps
(define-map caregivers
  { caregiver-id: uint }
  {
    principal: principal,
    name: (string-ascii 50),
    contact-info: (string-ascii 100),
    certification-status: (string-ascii 20),
    background-check-hash: (optional (buff 32)),
    skills: (list 10 (string-ascii 30)),
    safety-score: uint,
    certification-date: uint,
    expiry-date: uint,
    renewal-count: uint,
    active: bool
  }
)

(define-map caregiver-by-principal
  { principal: principal }
  { caregiver-id: uint }
)

(define-map background-checks
  { check-id: uint }
  {
    caregiver-id: uint,
    check-type: (string-ascii 30),
    status: (string-ascii 20),
    submission-date: uint,
    verification-date: (optional uint),
    verified-by: (optional principal),
    document-hash: (buff 32),
    notes: (optional (string-ascii 200))
  }
)

(define-map skill-assessments
  { assessment-id: uint }
  {
    caregiver-id: uint,
    skill-name: (string-ascii 30),
    proficiency-level: uint, ;; 1-5 scale
    assessor: principal,
    assessment-date: uint,
    valid-until: uint,
    certification-body: (optional (string-ascii 50))
  }
)

(define-map certification-history
  { history-id: uint }
  {
    caregiver-id: uint,
    action: (string-ascii 30),
    timestamp: uint,
    performed-by: principal,
    details: (optional (string-ascii 200))
  }
)

;; Data Variables for ID tracking
(define-data-var next-check-id uint u1)
(define-data-var next-assessment-id uint u1)
(define-data-var next-history-id uint u1)

;; Public Functions

;; Register a new caregiver
(define-public (register-caregiver (name (string-ascii 50)) (contact-info (string-ascii 100)))
  (let
    (
      (caregiver-id (var-get next-caregiver-id))
      (current-time u1000000)
    )
    (asserts! (is-none (map-get? caregiver-by-principal {principal: tx-sender})) err-already-exists)
    
    ;; Create caregiver record
    (map-set caregivers
      {caregiver-id: caregiver-id}
      {
        principal: tx-sender,
        name: name,
        contact-info: contact-info,
        certification-status: "pending",
        background-check-hash: none,
        skills: (list),
        safety-score: u0,
        certification-date: current-time,
        expiry-date: (+ current-time u31536000), ;; 1 year in seconds
        renewal-count: u0,
        active: true
      }
    )
    
    ;; Map principal to caregiver ID
    (map-set caregiver-by-principal
      {principal: tx-sender}
      {caregiver-id: caregiver-id}
    )
    
    ;; Log registration
    (unwrap-panic (log-certification-action caregiver-id "registered" tx-sender (some "Initial registration")))
    
    ;; Increment ID counter
    (var-set next-caregiver-id (+ caregiver-id u1))
    
    (ok caregiver-id)
  )
)

;; Submit background check documentation
(define-public (submit-background-check (caregiver-id uint) (check-type (string-ascii 30)) (document-hash (buff 32)))
  (let
    (
      (check-id (var-get next-check-id))
      (current-time u1000000)
      (caregiver (unwrap! (map-get? caregivers {caregiver-id: caregiver-id}) err-not-found))
    )
    (asserts! (is-eq tx-sender (get principal caregiver)) err-owner-only)
    
    ;; Create background check record
    (map-set background-checks
      {check-id: check-id}
      {
        caregiver-id: caregiver-id,
        check-type: check-type,
        status: "submitted",
        submission-date: current-time,
        verification-date: none,
        verified-by: none,
        document-hash: document-hash,
        notes: none
      }
    )
    
    ;; Update caregiver status
    (map-set caregivers
      {caregiver-id: caregiver-id}
      (merge caregiver {certification-status: "under-review"})
    )
    
    ;; Log action
    (unwrap-panic (log-certification-action caregiver-id "background-check-submitted" tx-sender (some check-type)))
    
    ;; Increment check ID
    (var-set next-check-id (+ check-id u1))
    
    (ok check-id)
  )
)

;; Approve or reject background check (admin function)
(define-public (verify-background-check (check-id uint) (approved bool) (notes (optional (string-ascii 200))))
  (let
    (
      (check (unwrap! (map-get? background-checks {check-id: check-id}) err-not-found))
      (current-time u1000000)
      (caregiver-id (get caregiver-id check))
    )
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    
    ;; Update background check
    (map-set background-checks
      {check-id: check-id}
      (merge check {
        status: (if approved "verified" "rejected"),
        verification-date: (some current-time),
        verified-by: (some tx-sender),
        notes: notes
      })
    )
    
    ;; Update caregiver certification if approved
    (if approved
      (begin
        (try! (update-caregiver-certification caregiver-id))
        (unwrap-panic (log-certification-action caregiver-id "background-check-approved" tx-sender notes))
      )
      (begin
        (try! (update-caregiver-status caregiver-id "rejected"))
        (unwrap-panic (log-certification-action caregiver-id "background-check-rejected" tx-sender notes))
      )
    )
    
    (ok approved)
  )
)

;; Add skill assessment
(define-public (add-skill-assessment (caregiver-id uint) (skill-name (string-ascii 30)) (proficiency-level uint) (certification-body (optional (string-ascii 50))))
  (let
    (
      (assessment-id (var-get next-assessment-id))
      (current-time u1000000)
      (caregiver (unwrap! (map-get? caregivers {caregiver-id: caregiver-id}) err-not-found))
    )
    (asserts! (and (>= proficiency-level u1) (<= proficiency-level u5)) err-invalid-status)
    (asserts! (or (is-eq tx-sender contract-owner) (is-eq tx-sender (get principal caregiver))) err-owner-only)
    
    ;; Create skill assessment
    (map-set skill-assessments
      {assessment-id: assessment-id}
      {
        caregiver-id: caregiver-id,
        skill-name: skill-name,
        proficiency-level: proficiency-level,
        assessor: tx-sender,
        assessment-date: current-time,
        valid-until: (+ current-time u15768000), ;; 6 months
        certification-body: certification-body
      }
    )
    
    ;; Update caregiver skills list
    (try! (update-caregiver-skills caregiver-id skill-name))
    
    ;; Log action
    (unwrap-panic (log-certification-action caregiver-id "skill-added" tx-sender (some skill-name)))
    
    ;; Increment assessment ID
    (var-set next-assessment-id (+ assessment-id u1))
    
    (ok assessment-id)
  )
)

;; Renew certification
(define-public (renew-certification (caregiver-id uint))
  (let
    (
      (caregiver (unwrap! (map-get? caregivers {caregiver-id: caregiver-id}) err-not-found))
      (current-time u1000000)
    )
    (asserts! (is-eq tx-sender (get principal caregiver)) err-owner-only)
    (asserts! (>= (get safety-score caregiver) (var-get minimum-safety-score)) err-insufficient-score)
    
    ;; Update certification
    (map-set caregivers
      {caregiver-id: caregiver-id}
      (merge caregiver {
        certification-date: current-time,
        expiry-date: (+ current-time u31536000), ;; 1 year
        renewal-count: (+ (get renewal-count caregiver) u1),
        certification-status: "certified"
      })
    )
    
    ;; Log renewal
    (unwrap-panic (log-certification-action caregiver-id "certification-renewed" tx-sender none))
    
    (ok true)
  )
)

;; Private Helper Functions

(define-private (update-caregiver-certification (caregiver-id uint))
  (let
    (
      (caregiver (unwrap! (map-get? caregivers {caregiver-id: caregiver-id}) err-not-found))
    )
    (map-set caregivers
      {caregiver-id: caregiver-id}
      (merge caregiver {
        certification-status: "certified",
        safety-score: u85 ;; Initial safety score for certified caregivers
      })
    )
    (ok true)
  )
)

(define-private (update-caregiver-status (caregiver-id uint) (status (string-ascii 20)))
  (let
    (
      (caregiver (unwrap! (map-get? caregivers {caregiver-id: caregiver-id}) err-not-found))
    )
    (map-set caregivers
      {caregiver-id: caregiver-id}
      (merge caregiver {certification-status: status})
    )
    (ok true)
  )
)

(define-private (update-caregiver-skills (caregiver-id uint) (skill-name (string-ascii 30)))
  (let
    (
      (caregiver (unwrap! (map-get? caregivers {caregiver-id: caregiver-id}) err-not-found))
      (current-skills (get skills caregiver))
    )
    ;; Add skill if not already present
    (if (is-none (index-of current-skills skill-name))
      (map-set caregivers
        {caregiver-id: caregiver-id}
        (merge caregiver {skills: (unwrap-panic (as-max-len? (append current-skills skill-name) u10))})
      )
      true
    )
    (ok true)
  )
)

(define-private (log-certification-action (caregiver-id uint) (action (string-ascii 30)) (performed-by principal) (details (optional (string-ascii 200))))
  (let
    (
      (history-id (var-get next-history-id))
      (current-time u1000000)
    )
    (map-set certification-history
      {history-id: history-id}
      {
        caregiver-id: caregiver-id,
        action: action,
        timestamp: current-time,
        performed-by: performed-by,
        details: details
      }
    )
    (var-set next-history-id (+ history-id u1))
    (ok history-id)
  )
)

;; Read-only Functions

(define-read-only (get-caregiver (caregiver-id uint))
  (map-get? caregivers {caregiver-id: caregiver-id})
)

(define-read-only (get-caregiver-by-principal (principal-address principal))
  (match (map-get? caregiver-by-principal {principal: principal-address})
    caregiver-data (map-get? caregivers {caregiver-id: (get caregiver-id caregiver-data)})
    none
  )
)

(define-read-only (get-background-check (check-id uint))
  (map-get? background-checks {check-id: check-id})
)

(define-read-only (get-skill-assessment (assessment-id uint))
  (map-get? skill-assessments {assessment-id: assessment-id})
)

(define-read-only (get-certification-history (history-id uint))
  (map-get? certification-history {history-id: history-id})
)

(define-read-only (is-certification-valid (caregiver-id uint))
  (match (map-get? caregivers {caregiver-id: caregiver-id})
    caregiver (and
      (get active caregiver)
      (is-eq (get certification-status caregiver) "certified")
      (> (get expiry-date caregiver) u1000000)
    )
    false
  )
)

(define-read-only (get-contract-info)
  {
    total-caregivers: (- (var-get next-caregiver-id) u1),
    certification-fee: (var-get certification-fee),
    minimum-safety-score: (var-get minimum-safety-score),
    total-background-checks: (- (var-get next-check-id) u1),
    total-skill-assessments: (- (var-get next-assessment-id) u1)
  }
)

;; title: caregiver-certification
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

