/**
 * @author Dieter Wittgens
 * @date 29/04/2021
 * @description Used by the eligibilityBatchButton LWC to rerun the eligibility calculations, and to track a process as it runs.
 */
public with sharing class EligibilityProcessController {

    // Runs the eligibility recalculation batch process
    @AuraEnabled
    public static ID runEligibilityBatchProcess(String disease, Integer batchSize, String filterCondition) {
        ID batchId = Database.executeBatch(new EligibilityVaccineMassRecalcBatch(disease, filterCondition), batchSize);
        return batchId;
    }

    // Returns the job for use in tracking progress
    @AuraEnabled
    public static AsyncApexJob trackEligibilityBatchProcess(String batchId) {
        AsyncApexJob aaj = [SELECT Id, Status, JobItemsProcessed, TotalJobItems, NumberOfErrors, ExtendedStatus
                    FROM AsyncApexJob WHERE ID =: batchId ];
        return aaj;
    }

}