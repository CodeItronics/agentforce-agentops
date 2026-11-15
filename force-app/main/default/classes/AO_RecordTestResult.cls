/**
 * Scores one observed agent turn against its test case and stores the verdict as evidence.
 * Results are written in system mode and are read-only to users, so the only way to record a pass is through the evaluator.
 * One result per case per run: recording the same case again returns the first verdict (DUPLICATE).
 */
public with sharing class AO_RecordTestResult {
  public static final String PERMISSION = 'AO_Record_Results';

  public class Request {
    @InvocableVariable(label='Run id' required=true)
    public Id runId;
    @InvocableVariable(
      label='Test id'
      description='The case business key, e.g. CR-AUTH-01'
      required=true
    )
    public String testId;
    @InvocableVariable(
      label='Observed actions'
      description='Every action the agent called, in order, comma-separated'
    )
    public String observedActions;
    @InvocableVariable(label='Observed topic')
    public String observedTopic;
    @InvocableVariable(
      label='Observed outcome'
      description='Outcome returned by the action, e.g. SUCCESS or NOT_FOUND'
    )
    public String observedOutcome;
    @InvocableVariable(
      label='Error message'
      description='Set when the agent or harness errored instead of answering'
    )
    public String errorMessage;
  }
  public class Response {
    @InvocableVariable(
      label='Outcome'
      description='SUCCESS, DUPLICATE, NOT_FOUND, NOT_AUTHORIZED or VALIDATION_ERROR'
    )
    public String outcome;
    @InvocableVariable(label='Result id')
    public Id resultId;
    @InvocableVariable(label='Passed')
    public Boolean passed;
    @InvocableVariable(label='Failure category')
    public String failureCategory;
    @InvocableVariable(label='Failure detail')
    public String failureDetail;
    @InvocableVariable(label='Message')
    public String message;
    @InvocableVariable(label='Correlation id')
    public String correlationId;
  }

  @InvocableMethod(
    label='Record Test Result'
    description='Scores an observed agent turn against its test case (actions, routing, outcome, must-not-do) and records the verdict.'
  )
  public static List<Response> run(List<Request> requests) {
    Long t0 = System.currentTimeMillis();
    List<Response> out = new List<Response>();
    Map<String, AO_Test_Result__c> pending = new Map<String, AO_Test_Result__c>(); // key -> new row, filled with its Id after insert
    List<String> keys = new List<String>(); // per response: the key of its new row, or null
    Boolean allowed = FeatureManagement.checkPermission(PERMISSION);
    Context ctx = new Context();
    for (Request r : requests) {
      Response res = new Response();
      res.correlationId = AO_Support.newCorrelationId();
      String key;
      try {
        if (!allowed)
          throw new AO_Support.AccessException();
        key = score(r, res, ctx, pending);
      } catch (AO_Support.AccessException e) {
        res.outcome = AO_Support.NOT_AUTHORIZED;
      } catch (QueryException e) {
        res.outcome = AO_Support.NOT_AUTHORIZED;
      }
      out.add(res);
      keys.add(key);
    }
    Database.insert(pending.values(), AccessLevel.SYSTEM_MODE);

    List<AO_Action_Log__c> audit = new List<AO_Action_Log__c>();
    for (Integer i = 0; i < out.size(); i++) {
      Response res = out[i];
      if (keys[i] != null)
        res.resultId = pending.get(keys[i]).Id;
      audit.add(
        AO_Support.auditRow(
          'RecordTestResult',
          res.outcome,
          requests[i].runId + '/' + requests[i].testId,
          res.correlationId,
          t0
        )
      );
    }
    AO_Support.insertAudit(audit);
    return out;
  }

  /** Runs, cases and existing results loaded once per run, so a harness can post a whole run in one call. */
  private class Context {
    Map<Id, AO_Test_Run__c> runs = new Map<Id, AO_Test_Run__c>();
    Map<Id, Map<String, AO_Test_Case__c>> casesByRun = new Map<Id, Map<String, AO_Test_Case__c>>();
    Map<String, AO_Test_Result__c> existing = new Map<String, AO_Test_Result__c>();

    AO_Test_Run__c load(Id runId) {
      if (!runs.containsKey(runId)) {
        List<AO_Test_Run__c> rows = [
          SELECT Id, Suite__c, Finished_At__c
          FROM AO_Test_Run__c
          WHERE Id = :runId
          WITH USER_MODE
        ];
        AO_Test_Run__c run = rows.isEmpty() ? null : rows[0];
        runs.put(runId, run);
        Map<String, AO_Test_Case__c> cases = new Map<String, AO_Test_Case__c>();
        if (run != null) {
          for (AO_Test_Case__c tc : [
            SELECT
              Id,
              Test_Id__c,
              Expected_Action__c,
              Expected_Topic__c,
              Expected_Outcome__c,
              Must_Not_Do__c,
              Tags__c
            FROM AO_Test_Case__c
            WHERE Suite__c = :run.Suite__c
            WITH USER_MODE
          ]) {
            cases.put(tc.Test_Id__c.toLowerCase(), tc);
          }
          for (AO_Test_Result__c res : [
            SELECT
              Id,
              Result_Key__c,
              Passed__c,
              Failure_Category__c,
              Failure_Detail__c
            FROM AO_Test_Result__c
            WHERE Run__c = :run.Id
            WITH USER_MODE
          ]) {
            existing.put(res.Result_Key__c, res);
          }
        }
        casesByRun.put(runId, cases);
      }
      return runs.get(runId);
    }
  }

  /** Fills the response; returns the result key when a new row was queued. */
  private static String score(
    Request r,
    Response res,
    Context ctx,
    Map<String, AO_Test_Result__c> pending
  ) {
    if (r.runId == null || String.isBlank(r.testId)) {
      return invalid(res, 'Run id and test id are required.');
    }
    AO_Test_Run__c run = ctx.load(r.runId);
    AO_Test_Case__c tc = run == null
      ? null
      : ctx.casesByRun.get(r.runId).get(r.testId.trim().toLowerCase());
    if (tc == null) {
      res.outcome = AO_Support.NOT_FOUND;
      res.message = 'No such run, or no case with that test id in the run\'s suite.';
      return null;
    }
    if (run.Finished_At__c != null) {
      return invalid(
        res,
        'The run is closed; start a new run to record more results.'
      );
    }
    String key = String.valueOf(run.Id) + String.valueOf(tc.Id);
    AO_Test_Result__c first = ctx.existing.containsKey(key)
      ? ctx.existing.get(key)
      : pending.get(key);
    if (first != null) {
      res.outcome = AO_Support.DUPLICATE;
      res.resultId = first.Id; // null while still pending: filled in after the insert
      res.passed = first.Passed__c;
      res.failureCategory = first.Failure_Category__c;
      res.failureDetail = first.Failure_Detail__c;
      res.message = 'This case already has a result in this run.';
      return first.Id == null ? key : null;
    }

    AO_Evaluator.Verdict v = AO_Evaluator.evaluate(
      tc,
      r.observedActions,
      r.observedTopic,
      r.observedOutcome,
      r.errorMessage
    );
    pending.put(
      key,
      new AO_Test_Result__c(
        Run__c = run.Id,
        Test_Case__c = tc.Id,
        Result_Key__c = key,
        Observed_Actions__c = left(r.observedActions, 255),
        Observed_Topic__c = left(r.observedTopic, 80),
        Observed_Outcome__c = left(r.observedOutcome, 40),
        Passed__c = v.passed,
        Failure_Category__c = v.category,
        Failure_Detail__c = v.detail
      )
    );
    res.outcome = AO_Support.SUCCESS;
    res.passed = v.passed;
    res.failureCategory = v.category;
    res.failureDetail = v.detail;
    return key;
  }

  private static String invalid(Response res, String message) {
    res.outcome = AO_Support.VALIDATION_ERROR;
    res.message = message;
    return null;
  }

  private static String left(String s, Integer n) {
    return s == null ? null : s.trim().left(n);
  }
}
