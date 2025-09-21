;; Community Childcare Network - Care Coordination Contract
;; Schedule and coordinate childcare services between families and caregivers

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-found (err u201))
(define-constant err-already-exists (err u202))
(define-constant err-invalid-status (err u203))
(define-constant err-unauthorized (err u204))
(define-constant err-time-conflict (err u205))
(define-constant err-invalid-payment (err u206))
(define-constant err-service-expired (err u207))

;; Data Variables
(define-data-var next-request-id uint u1)
(define-data-var next-session-id uint u1)
(define-data-var platform-fee-percent uint u5) ;; 5% platform fee
(define-data-var minimum-advance-hours uint u24) ;; 24 hours minimum advance booking

;; Data Maps
(define-map care-requests
  { request-id: uint }
  {
    family-principal: principal,
    caregiver-principal: (optional principal),
    children-count: uint,
    ages: (list 5 uint),
    start-time: uint,
    end-time: uint,
    hourly-rate: uint,
    total-payment: uint,
    special-requirements: (optional (string-ascii 200)),
    location: (string-ascii 100),
    status: (string-ascii 20), ;; "open", "accepted", "in-progress", "completed", "cancelled"
    created-at: uint,
    updated-at: uint,
    emergency-contact: (string-ascii 100),
    payment-status: (string-ascii 20) ;; "pending", "escrow", "released", "refunded"
  }
)

(define-map care-sessions
  { session-id: uint }
  {
    request-id: uint,
    family-principal: principal,
    caregiver-principal: principal,
    actual-start-time: (optional uint),
    actual-end-time: (optional uint),
    session-notes: (optional (string-ascii 300)),
    family-rating: (optional uint), ;; 1-5 scale
    caregiver-rating: (optional uint), ;; 1-5 scale
    family-feedback: (optional (string-ascii 200)),
    caregiver-feedback: (optional (string-ascii 200)),
    session-status: (string-ascii 20), ;; "scheduled", "started", "completed", "cancelled"
    created-at: uint,
    completion-confirmed: bool
  }
)

(define-map caregiver-availability
  { caregiver: principal, time-slot: uint }
  {
    available: bool,
    hourly-rate: uint,
    max-children: uint,
    updated-at: uint
  }
)

(define-map family-profiles
  { family-principal: principal }
  {
    contact-info: (string-ascii 100),
    children-info: (string-ascii 300),
    preferred-rate: uint,
    emergency-contact: (string-ascii 100),
    special-instructions: (optional (string-ascii 200)),
    active: bool,
    created-at: uint,
    total-requests: uint
  }
)

(define-map caregiver-profiles
  { caregiver-principal: principal }
  {
    contact-info: (string-ascii 100),
    base-hourly-rate: uint,
    max-children-capacity: uint,
    service-area: (string-ascii 100),
    available-days: (list 7 bool), ;; Mon-Sun availability
    active: bool,
    created-at: uint,
    total-sessions: uint,
    average-rating: uint
  }
)

(define-map payment-escrow
  { request-id: uint }
  {
    amount: uint,
    deposited-by: principal,
    deposit-time: uint,
    released: bool,
    release-time: (optional uint),
    recipient: (optional principal)
  }
)

;; Public Functions

;; Register family profile
(define-public (register-family-profile (contact-info (string-ascii 100)) (children-info (string-ascii 300)) (preferred-rate uint) (emergency-contact (string-ascii 100)))
  (let
    (
      (current-time u1000000)
    )
    (asserts! (is-none (map-get? family-profiles {family-principal: tx-sender})) err-already-exists)
    
    (map-set family-profiles
      {family-principal: tx-sender}
      {
        contact-info: contact-info,
        children-info: children-info,
        preferred-rate: preferred-rate,
        emergency-contact: emergency-contact,
        special-instructions: none,
        active: true,
        created-at: current-time,
        total-requests: u0
      }
    )
    
    (ok true)
  )
)

;; Register caregiver profile
(define-public (register-caregiver-profile (contact-info (string-ascii 100)) (base-hourly-rate uint) (max-children-capacity uint) (service-area (string-ascii 100)))
  (let
    (
      (current-time u1000000)
      (default-availability (list true true true true true false false)) ;; Default Mon-Fri availability
    )
    (asserts! (is-none (map-get? caregiver-profiles {caregiver-principal: tx-sender})) err-already-exists)
    
    (map-set caregiver-profiles
      {caregiver-principal: tx-sender}
      {
        contact-info: contact-info,
        base-hourly-rate: base-hourly-rate,
        max-children-capacity: max-children-capacity,
        service-area: service-area,
        available-days: default-availability,
        active: true,
        created-at: current-time,
        total-sessions: u0,
        average-rating: u0
      }
    )
    
    (ok true)
  )
)

;; Create care request
(define-public (create-care-request (children-count uint) (ages (list 5 uint)) (start-time uint) (end-time uint) (hourly-rate uint) (location (string-ascii 100)) (special-requirements (optional (string-ascii 200))))
  (let
    (
      (request-id (var-get next-request-id))
      (current-time u1000000)
      (family-profile (unwrap! (map-get? family-profiles {family-principal: tx-sender}) err-not-found))
      (duration-hours (/ (- end-time start-time) u3600))
      (total-payment (* duration-hours hourly-rate))
      (advance-time (- start-time current-time))
    )
    (asserts! (> children-count u0) err-invalid-status)
    (asserts! (> end-time start-time) err-invalid-status)
    (asserts! (> advance-time (* (var-get minimum-advance-hours) u3600)) err-invalid-status)
    (asserts! (get active family-profile) err-unauthorized)
    
    ;; Create care request
    (map-set care-requests
      {request-id: request-id}
      {
        family-principal: tx-sender,
        caregiver-principal: none,
        children-count: children-count,
        ages: ages,
        start-time: start-time,
        end-time: end-time,
        hourly-rate: hourly-rate,
        total-payment: total-payment,
        special-requirements: special-requirements,
        location: location,
        status: "open",
        created-at: current-time,
        updated-at: current-time,
        emergency-contact: (get emergency-contact family-profile),
        payment-status: "pending"
      }
    )
    
    ;; Update family profile request count
    (map-set family-profiles
      {family-principal: tx-sender}
      (merge family-profile {total-requests: (+ (get total-requests family-profile) u1)})
    )
    
    ;; Increment request ID
    (var-set next-request-id (+ request-id u1))
    
    (ok request-id)
  )
)

;; Accept care request (caregiver)
(define-public (accept-care-request (request-id uint))
  (let
    (
      (request (unwrap! (map-get? care-requests {request-id: request-id}) err-not-found))
      (current-time u1000000)
      (caregiver-profile (unwrap! (map-get? caregiver-profiles {caregiver-principal: tx-sender}) err-not-found))
    )
    (asserts! (is-eq (get status request) "open") err-invalid-status)
    (asserts! (get active caregiver-profile) err-unauthorized)
    (asserts! (>= (get max-children-capacity caregiver-profile) (get children-count request)) err-invalid-status)
    
    ;; Check for time conflicts
    (asserts! (is-none (get-caregiver-conflict tx-sender (get start-time request) (get end-time request))) err-time-conflict)
    
    ;; Update request with caregiver
    (map-set care-requests
      {request-id: request-id}
      (merge request {
        caregiver-principal: (some tx-sender),
        status: "accepted",
        updated-at: current-time
      })
    )
    
    ;; Create care session
    (try! (create-care-session request-id))
    
    (ok true)
  )
)

;; Start care session
(define-public (start-care-session (session-id uint))
  (let
    (
      (session (unwrap! (map-get? care-sessions {session-id: session-id}) err-not-found))
      (current-time u1000000)
    )
    (asserts! (is-eq tx-sender (get caregiver-principal session)) err-unauthorized)
    (asserts! (is-eq (get session-status session) "scheduled") err-invalid-status)
    
    ;; Update session start
    (map-set care-sessions
      {session-id: session-id}
      (merge session {
        actual-start-time: (some current-time),
        session-status: "started"
      })
    )
    
    ;; Update request status
    (try! (update-request-status (get request-id session) "in-progress"))
    
    (ok true)
  )
)

;; Complete care session
(define-public (complete-care-session (session-id uint) (session-notes (optional (string-ascii 300))))
  (let
    (
      (session (unwrap! (map-get? care-sessions {session-id: session-id}) err-not-found))
      (current-time u1000000)
    )
    (asserts! (is-eq tx-sender (get caregiver-principal session)) err-unauthorized)
    (asserts! (is-eq (get session-status session) "started") err-invalid-status)
    
    ;; Update session completion
    (map-set care-sessions
      {session-id: session-id}
      (merge session {
        actual-end-time: (some current-time),
        session-notes: session-notes,
        session-status: "completed"
      })
    )
    
    ;; Update request status
    (try! (update-request-status (get request-id session) "completed"))
    
    ;; Update caregiver session count
    (try! (increment-caregiver-sessions (get caregiver-principal session)))
    
    (ok true)
  )
)

;; Submit rating and feedback
(define-public (submit-rating (session-id uint) (rating uint) (feedback (optional (string-ascii 200))))
  (let
    (
      (session (unwrap! (map-get? care-sessions {session-id: session-id}) err-not-found))
      (is-family (is-eq tx-sender (get family-principal session)))
      (is-caregiver (is-eq tx-sender (get caregiver-principal session)))
    )
    (asserts! (is-eq (get session-status session) "completed") err-invalid-status)
    (asserts! (and (>= rating u1) (<= rating u5)) err-invalid-status)
    (asserts! (or is-family is-caregiver) err-unauthorized)
    
    ;; Update session with rating
    (if is-family
      (map-set care-sessions
        {session-id: session-id}
        (merge session {
          family-rating: (some rating),
          family-feedback: feedback
        })
      )
      (map-set care-sessions
        {session-id: session-id}
        (merge session {
          caregiver-rating: (some rating),
          caregiver-feedback: feedback
        })
      )
    )
    
    ;; Update caregiver average rating if family submitted rating
    (if is-family
      (try! (update-caregiver-rating (get caregiver-principal session) rating))
      true
    )
    
    (ok true)
  )
)

;; Deposit payment to escrow
(define-public (deposit-payment (request-id uint))
  (let
    (
      (request (unwrap! (map-get? care-requests {request-id: request-id}) err-not-found))
      (current-time u1000000)
    )
    (asserts! (is-eq tx-sender (get family-principal request)) err-unauthorized)
    (asserts! (is-eq (get payment-status request) "pending") err-invalid-status)
    (asserts! (is-some (get caregiver-principal request)) err-invalid-status)
    
    ;; TODO: Implement STX transfer to escrow (would require STX handling)
    
    ;; Create escrow record
    (map-set payment-escrow
      {request-id: request-id}
      {
        amount: (get total-payment request),
        deposited-by: tx-sender,
        deposit-time: current-time,
        released: false,
        release-time: none,
        recipient: none
      }
    )
    
    ;; Update request payment status
    (map-set care-requests
      {request-id: request-id}
      (merge request {payment-status: "escrow"})
    )
    
    (ok true)
  )
)

;; Release payment after service completion
(define-public (release-payment (request-id uint))
  (let
    (
      (request (unwrap! (map-get? care-requests {request-id: request-id}) err-not-found))
      (escrow (unwrap! (map-get? payment-escrow {request-id: request-id}) err-not-found))
      (current-time u1000000)
    )
    (asserts! (is-eq tx-sender (get family-principal request)) err-unauthorized)
    (asserts! (is-eq (get status request) "completed") err-invalid-status)
    (asserts! (is-eq (get payment-status request) "escrow") err-invalid-status)
    (asserts! (not (get released escrow)) err-invalid-status)
    
    ;; TODO: Implement STX transfer from escrow to caregiver
    
    ;; Update escrow release
    (map-set payment-escrow
      {request-id: request-id}
      (merge escrow {
        released: true,
        release-time: (some current-time),
        recipient: (get caregiver-principal request)
      })
    )
    
    ;; Update request payment status
    (map-set care-requests
      {request-id: request-id}
      (merge request {payment-status: "released"})
    )
    
    (ok true)
  )
)

;; Private Helper Functions

(define-private (create-care-session (request-id uint))
  (let
    (
      (session-id (var-get next-session-id))
      (request (unwrap! (map-get? care-requests {request-id: request-id}) err-not-found))
      (current-time u1000000)
    )
    (map-set care-sessions
      {session-id: session-id}
      {
        request-id: request-id,
        family-principal: (get family-principal request),
        caregiver-principal: (unwrap-panic (get caregiver-principal request)),
        actual-start-time: none,
        actual-end-time: none,
        session-notes: none,
        family-rating: none,
        caregiver-rating: none,
        family-feedback: none,
        caregiver-feedback: none,
        session-status: "scheduled",
        created-at: current-time,
        completion-confirmed: false
      }
    )
    
    (var-set next-session-id (+ session-id u1))
    (ok session-id)
  )
)

(define-private (update-request-status (request-id uint) (new-status (string-ascii 20)))
  (let
    (
      (request (unwrap! (map-get? care-requests {request-id: request-id}) err-not-found))
      (current-time u1000000)
    )
    (map-set care-requests
      {request-id: request-id}
      (merge request {
        status: new-status,
        updated-at: current-time
      })
    )
    (ok true)
  )
)

(define-private (get-caregiver-conflict (caregiver principal) (start-time uint) (end-time uint))
  ;; Simplified conflict checking - would need more complex logic for real implementation
  none
)

(define-private (increment-caregiver-sessions (caregiver principal))
  (let
    (
      (profile (unwrap! (map-get? caregiver-profiles {caregiver-principal: caregiver}) err-not-found))
    )
    (map-set caregiver-profiles
      {caregiver-principal: caregiver}
      (merge profile {total-sessions: (+ (get total-sessions profile) u1)})
    )
    (ok true)
  )
)

(define-private (update-caregiver-rating (caregiver principal) (new-rating uint))
  (let
    (
      (profile (unwrap! (map-get? caregiver-profiles {caregiver-principal: caregiver}) err-not-found))
      (current-avg (get average-rating profile))
      (session-count (get total-sessions profile))
      (new-avg (if (is-eq current-avg u0)
        new-rating
        (/ (+ (* current-avg session-count) new-rating) (+ session-count u1))
      ))
    )
    (map-set caregiver-profiles
      {caregiver-principal: caregiver}
      (merge profile {average-rating: new-avg})
    )
    (ok true)
  )
)

;; Read-only Functions

(define-read-only (get-care-request (request-id uint))
  (map-get? care-requests {request-id: request-id})
)

(define-read-only (get-care-session (session-id uint))
  (map-get? care-sessions {session-id: session-id})
)

(define-read-only (get-family-profile (family-principal principal))
  (map-get? family-profiles {family-principal: family-principal})
)

(define-read-only (get-caregiver-profile (caregiver-principal principal))
  (map-get? caregiver-profiles {caregiver-principal: caregiver-principal})
)

(define-read-only (get-payment-escrow (request-id uint))
  (map-get? payment-escrow {request-id: request-id})
)

(define-read-only (get-caregiver-availability (caregiver principal) (time-slot uint))
  (map-get? caregiver-availability {caregiver: caregiver, time-slot: time-slot})
)

(define-read-only (get-contract-stats)
  {
    total-requests: (- (var-get next-request-id) u1),
    total-sessions: (- (var-get next-session-id) u1),
    platform-fee-percent: (var-get platform-fee-percent),
    minimum-advance-hours: (var-get minimum-advance-hours)
  }
)

;; title: care-coordination
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

