use fedimint_client::OperationId;
use fedimint_core::module::serde_json;
use fedimint_eventlog::{Event, EventLogEntry};
use fedimint_lnv2_client::events::SendPaymentStatus as LnSendPaymentStatus;
use fedimint_mint_client::event::ReceivePaymentStatus as MintReceivePaymentStatus;
use fedimint_wallet_client::events::SendPaymentStatus as WalletSendPaymentStatus;

/// A parsed payment from the event log with all relevant fields
pub(crate) struct ParsedPayment {
    pub operation_id: OperationId,
    pub incoming: bool,
    pub module: &'static str,
    pub amount_msats: u64,
    pub fee_msats: Option<u64>,
    pub timestamp_ms: i64,
    pub success: Option<bool>,
    pub oob: Option<String>,
}

/// Either a new payment or an update to an existing one
pub(crate) enum ParsedEvent {
    Payment(ParsedPayment),
    Update {
        operation_id: OperationId,
        success: bool,
        oob: Option<String>,
    },
}

/// Fold an update into a payment list by operation_id, returning the updated payment info
pub(crate) fn apply_update(
    payments: &mut [ParsedPayment],
    operation_id: &OperationId,
    success: bool,
    oob: Option<String>,
) {
    if let Some(payment) = payments
        .iter_mut()
        .rfind(|p| p.operation_id == *operation_id)
    {
        payment.success = Some(success);
        if oob.is_some() {
            payment.oob = oob;
        }
    }
}

/// Parse a raw EventLogEntry into a ParsedEvent
pub(crate) fn parse_event_log_entry(entry: &EventLogEntry) -> Option<ParsedEvent> {
    // LNv2 send (outgoing, pending)
    if let Some(send) = parse::<fedimint_lnv2_client::events::SendPaymentEvent>(entry) {
        return Some(ParsedEvent::Payment(ParsedPayment {
            operation_id: send.operation_id,
            incoming: false,
            module: "lnv2",
            amount_msats: send.amount.msats,
            fee_msats: send.fee.map(|fee| fee.msats),
            timestamp_ms: (entry.ts_usecs / 1000) as i64,
            success: None,
            oob: None,
        }));
    }

    // LNv2 send update (success with preimage, or refunded)
    if let Some(update) = parse::<fedimint_lnv2_client::events::SendPaymentUpdateEvent>(entry) {
        let (success, oob) = match update.status {
            LnSendPaymentStatus::Success(preimage) => (true, Some(hex::encode(preimage))),
            LnSendPaymentStatus::Refunded => (false, None),
        };
        return Some(ParsedEvent::Update {
            operation_id: update.operation_id,
            success,
            oob,
        });
    }

    // LNv2 receive (incoming, immediately successful)
    if let Some(receive) = parse::<fedimint_lnv2_client::events::ReceivePaymentEvent>(entry) {
        return Some(ParsedEvent::Payment(ParsedPayment {
            operation_id: receive.operation_id,
            incoming: true,
            module: "lnv2",
            amount_msats: receive.amount.msats,
            fee_msats: None,
            timestamp_ms: (entry.ts_usecs / 1000) as i64,
            success: Some(true),
            oob: None,
        }));
    }

    // Ecash send (outgoing, immediately successful, has oob_notes)
    if let Some(send) = parse::<fedimint_mint_client::event::SendPaymentEvent>(entry) {
        return Some(ParsedEvent::Payment(ParsedPayment {
            operation_id: send.operation_id,
            incoming: false,
            module: "mint",
            amount_msats: send.amount.msats,
            fee_msats: None,
            timestamp_ms: (entry.ts_usecs / 1000) as i64,
            success: Some(true),
            oob: Some(send.oob_notes),
        }));
    }

    // Ecash receive (incoming, pending)
    if let Some(receive) = parse::<fedimint_mint_client::event::ReceivePaymentEvent>(entry) {
        return Some(ParsedEvent::Payment(ParsedPayment {
            operation_id: receive.operation_id,
            incoming: true,
            module: "mint",
            amount_msats: receive.amount.msats,
            fee_msats: None,
            timestamp_ms: (entry.ts_usecs / 1000) as i64,
            success: None,
            oob: None,
        }));
    }

    // Ecash receive update
    if let Some(update) = parse::<fedimint_mint_client::event::ReceivePaymentUpdateEvent>(entry) {
        return Some(ParsedEvent::Update {
            operation_id: update.operation_id,
            success: matches!(update.status, MintReceivePaymentStatus::Success),
            oob: None,
        });
    }

    // On-chain send (outgoing, pending)
    if let Some(send) = parse::<fedimint_wallet_client::events::SendPaymentEvent>(entry) {
        return Some(ParsedEvent::Payment(ParsedPayment {
            operation_id: send.operation_id,
            incoming: false,
            module: "wallet",
            amount_msats: send.amount.to_sat() * 1000,
            fee_msats: Some(send.fee.to_sat() * 1000),
            timestamp_ms: (entry.ts_usecs / 1000) as i64,
            success: None,
            oob: None,
        }));
    }

    // On-chain send status update (success with txid, or aborted)
    if let Some(status) = parse::<fedimint_wallet_client::events::SendPaymentStatusEvent>(entry) {
        let (success, oob) = match status.status {
            WalletSendPaymentStatus::Success(txid) => (true, Some(txid.to_string())),
            WalletSendPaymentStatus::Aborted => (false, None),
        };
        return Some(ParsedEvent::Update {
            operation_id: status.operation_id,
            success,
            oob,
        });
    }

    // On-chain receive (incoming, immediately successful, has txid)
    if let Some(receive) = parse::<fedimint_wallet_client::events::ReceivePaymentEvent>(entry) {
        return Some(ParsedEvent::Payment(ParsedPayment {
            operation_id: receive.operation_id,
            incoming: true,
            module: "wallet",
            amount_msats: receive.amount.msats,
            fee_msats: None,
            timestamp_ms: (entry.ts_usecs / 1000) as i64,
            success: Some(true),
            oob: Some(receive.txid.to_string()),
        }));
    }

    None
}

fn parse<T: Event>(entry: &EventLogEntry) -> Option<T> {
    if entry.module.clone().map(|m| m.0) != T::MODULE {
        return None;
    }

    if entry.kind != T::KIND {
        return None;
    }

    serde_json::from_slice::<T>(&entry.payload).ok()
}
