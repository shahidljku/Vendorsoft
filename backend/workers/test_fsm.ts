import { PaymentFSM } from './src/services/fsm/paymentFSM';
import { SubscriptionFSM } from './src/services/fsm/subscriptionFSM';
import { TransferFSM } from './src/services/fsm/transferFSM';
import { InstallationFSM } from './src/services/fsm/installationFSM';

let failures = 0;

function assertTransition(fsm: any, status: string | null, action: string, expected: string) {
    try {
        const result = fsm.transition({ status }, action);
        if (result !== expected) {
            console.error(`FAIL: ${fsm.name}.transition({ status: ${status} }, '${action}') => ${result}, expected ${expected}`);
            failures++;
        } else {
            console.log(`PASS: ${fsm.name}.transition({ status: ${status} }, '${action}') => ${result}`);
        }
    } catch (e: any) {
        console.error(`FAIL: ${fsm.name}.transition({ status: ${status} }, '${action}') threw error: ${e.message}`);
        failures++;
    }
}

function assertIllegal(fsm: any, status: string | null, action: string) {
    try {
        fsm.transition({ status }, action);
        console.error(`FAIL: ${fsm.name}.transition({ status: ${status} }, '${action}') should have thrown, but succeeded`);
        failures++;
    } catch (e: any) {
        if (e.message.includes('ILLEGAL_TRANSITION')) {
            console.log(`PASS: ${fsm.name}.transition({ status: ${status} }, '${action}') correctly threw ILLEGAL_TRANSITION`);
        } else {
            console.error(`FAIL: ${fsm.name}.transition({ status: ${status} }, '${action}') threw wrong error: ${e.message}`);
            failures++;
        }
    }
}

// PaymentFSM
assertTransition(PaymentFSM, null, 'INITIATE', 'INITIATED');
assertIllegal(PaymentFSM, null, 'SETTLE');
assertTransition(PaymentFSM, 'INITIATED', 'FAIL', 'FAILED');
assertTransition(PaymentFSM, 'INITIATED', 'SETTLE', 'SUCCESS');
assertTransition(PaymentFSM, 'SUCCESS', 'REQUEST_REFUND', 'REFUND_PENDING');
assertTransition(PaymentFSM, 'REFUND_PENDING', 'COMPLETE_REFUND', 'REFUNDED');
assertIllegal(PaymentFSM, 'REFUNDED', 'SETTLE');
assertIllegal(PaymentFSM, 'FAILED', 'SETTLE');
assertIllegal(PaymentFSM, 'SUCCESS', 'SETTLE');

// SubscriptionFSM
assertTransition(SubscriptionFSM, null, 'ACTIVATE', 'ACTIVE');
assertTransition(SubscriptionFSM, 'ACTIVE', 'CANCEL', 'CANCELLED');
assertIllegal(SubscriptionFSM, 'CANCELLED', 'CANCEL');

// TransferFSM
assertTransition(TransferFSM, null, 'REQUEST', 'PENDING');
assertTransition(TransferFSM, 'PENDING', 'APPROVE', 'APPROVED');
assertTransition(TransferFSM, 'PENDING', 'REJECT', 'REJECTED');
assertTransition(TransferFSM, 'PENDING', 'CANCEL', 'CANCELLED');
assertIllegal(TransferFSM, 'APPROVED', 'APPROVE');
assertIllegal(TransferFSM, 'REJECTED', 'APPROVE');

// InstallationFSM
assertTransition(InstallationFSM, null, 'ACTIVATE', 'ACTIVE');
assertTransition(InstallationFSM, null, 'REVOKE', 'REVOKED');
assertTransition(InstallationFSM, 'ACTIVE', 'REVOKE', 'REVOKED');
assertTransition(InstallationFSM, 'ACTIVE', 'BAN', 'BANNED');
assertTransition(InstallationFSM, 'REVOKED', 'BAN', 'BANNED');
assertIllegal(InstallationFSM, 'BANNED', 'REVOKE');
assertIllegal(InstallationFSM, 'BANNED', 'BAN');

if (failures > 0) {
    console.error(`\nCompleted with ${failures} failures.`);
    process.exit(1);
} else {
    console.log(`\nAll tests passed successfully!`);
}
