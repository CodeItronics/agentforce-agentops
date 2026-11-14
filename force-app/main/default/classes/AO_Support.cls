/**
 * Shared helpers for the AgentOps actions: contract outcomes, list parsing and the audit row.
 */
public with sharing class AO_Support {
    public static final String SUCCESS = 'SUCCESS';
    public static final String NOT_FOUND = 'NOT_FOUND';
    public static final String NOT_AUTHORIZED = 'NOT_AUTHORIZED';
    public static final String VALIDATION_ERROR = 'VALIDATION_ERROR';
    public static final String DUPLICATE = 'DUPLICATE';

    public class AccessException extends Exception {}
    public class ValidationException extends Exception {}

    /** Splits "a, b; c" or one-per-line text into trimmed, non-blank items, keeping order. */
    public static List<String> splitList(String value) {
        List<String> out = new List<String>();
        if (String.isBlank(value)) return out;
        for (String part : value.split('[,;\\n]')) {
            if (String.isNotBlank(part)) out.add(part.trim());
        }
        return out;
    }

    /** Lower-cased set of the same items, for case-insensitive membership checks. */
    public static Set<String> lowerSet(String value) {
        Set<String> out = new Set<String>();
        for (String s : splitList(value)) out.add(s.toLowerCase());
        return out;
    }

    public static String newCorrelationId() {
        return 'CORR-' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(12).toUpperCase();
    }

    /** Audit row; the caller inserts the batch with insertAudit. */
    public static AO_Action_Log__c auditRow(String action, String outcome, String ref, String correlationId, Long startedMs) {
        return new AO_Action_Log__c(
            Action__c = action, Outcome__c = outcome, Record_Ref__c = ref == null ? null : ref.left(255),
            Correlation_Id__c = correlationId, Duration_Ms__c = System.currentTimeMillis() - startedMs
        );
    }

    /** Written in system mode so an evaluator needs no access to the log object. */
    public static void insertAudit(List<AO_Action_Log__c> rows) {
        Database.insert(rows, AccessLevel.SYSTEM_MODE);
    }
}
