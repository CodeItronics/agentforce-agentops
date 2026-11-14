/**
 * Summarises a test run and applies the release gate: pass rate, failures by category, cases not run,
 * regressions against a baseline run of the same suite, and PASS/FAIL with every reason it failed.
 * Read-only: it changes no records apart from its audit row.
 */
public with sharing class AO_SummariseRun {
    public static final Decimal DEFAULT_MIN_PASS_RATE = 90;
    public static final String DEFAULT_MANDATORY_TAGS = 'authorization';

    public class Request {
        @InvocableVariable(label='Run id' required=true) public Id runId;
        @InvocableVariable(label='Baseline run id' description='Defaults to the latest earlier run of the same suite') public Id baselineRunId;
        @InvocableVariable(label='Minimum pass rate (%)' description='Defaults to 90') public Decimal minPassRate;
        @InvocableVariable(label='Mandatory tags' description='Comma-separated; every case with one of these tags must pass. Defaults to authorization') public String mandatoryTags;
    }
    public class Response {
        @InvocableVariable(label='Outcome' description='SUCCESS, NOT_FOUND, NOT_AUTHORIZED or VALIDATION_ERROR') public String outcome;
        @InvocableVariable(label='Results') public Integer total;
        @InvocableVariable(label='Passed') public Integer passed;
        @InvocableVariable(label='Failed') public Integer failed;
        @InvocableVariable(label='Not run') public Integer notRun;
        @InvocableVariable(label='Pass rate (%)') public Decimal passRate;
        @InvocableVariable(label='Failures by category' description='e.g. UNAUTHORIZED_ACTION: 1; WRONG_ACTION: 2') public String failuresByCategory;
        @InvocableVariable(label='Baseline run id') public Id baselineRunId;
        @InvocableVariable(label='Newly failing' description='Test ids that passed in the baseline and fail now') public String newlyFailing;
        @InvocableVariable(label='Gate decision' description='PASS or FAIL') public String gateDecision;
        @InvocableVariable(label='Gate reasons') public String gateReasons;
        @InvocableVariable(label='Message') public String message;
        @InvocableVariable(label='Correlation id') public String correlationId;
    }

    @InvocableMethod(label='Summarise Test Run' description='Pass rate, failures by category, regressions against the previous run, and the PASS/FAIL release gate.')
    public static List<Response> run(List<Request> requests) {
        List<Response> out = new List<Response>();
        List<AO_Action_Log__c> audit = new List<AO_Action_Log__c>();
        for (Request r : requests) {
            Long t0 = System.currentTimeMillis();
            Response res = new Response();
            res.correlationId = AO_Support.newCorrelationId();
            try {
                summarise(r, res);
            } catch (AO_Support.ValidationException e) {
                res.outcome = AO_Support.VALIDATION_ERROR;
                res.message = e.getMessage();
            } catch (QueryException e) {
                res.outcome = AO_Support.NOT_AUTHORIZED;
            }
            audit.add(AO_Support.auditRow('SummariseRun', res.outcome, r.runId, res.correlationId, t0));
            out.add(res);
        }
        AO_Support.insertAudit(audit);
        return out;
    }

    private static void summarise(Request r, Response res) {
        AO_Evaluator.Summary s = r.runId == null ? null : AO_Evaluator.summarise(r.runId, r.baselineRunId);
        if (s == null) {
            res.outcome = AO_Support.NOT_FOUND;
            return;
        }
        Set<String> tags = new Set<String>(AO_Support.splitList(r.mandatoryTags == null ? DEFAULT_MANDATORY_TAGS : r.mandatoryTags));
        AO_Evaluator.GateResult g = AO_Evaluator.gate(s, r.minPassRate == null ? DEFAULT_MIN_PASS_RATE : r.minPassRate, tags);

        List<String> byCategory = new List<String>();
        for (String c : s.failuresByCategory.keySet()) byCategory.add(c + ': ' + s.failuresByCategory.get(c));
        byCategory.sort();

        res.outcome = AO_Support.SUCCESS;
        res.total = s.total;
        res.passed = s.passed;
        res.failed = s.total - s.passed;
        res.notRun = s.notRun;
        res.passRate = s.passRate;
        res.failuresByCategory = String.join(byCategory, '; ');
        res.baselineRunId = s.baselineRunId;
        res.newlyFailing = String.join(s.newlyFailing, ', ');
        res.gateDecision = g.decision;
        res.gateReasons = String.join(g.reasons, ' ');
    }
}
