/**
 * @author David Browaeys
 * @date 28/04/2021
 * @description This batch run for all cases which are linked to COVID19 and were flag as Not Eligible. 
 * It will call the eligibility vaccine rule engine that will return the list of candidate vaccine
 * @example 
 * Database.executeBatch(new EligibilityVaccineMassRecalcBatch('COVID19'),200);
 */
public without sharing class EligibilityVaccineMassRecalcBatch implements Database.Batchable<SObject>{
    public static final String query = 'SELECT ID, AccountId, Status, Eligibility_Status__c, Consent_Status__c FROM Case WHERE RecordType.DeveloperName = \'Vaccine_Application\' AND Disease__c = :diseaseKey AND ContactId NOT IN (SELECT Recipient_Patient__c FROM HealthCloudGA__EhrImmunization__c WHERE Status__c = \'Complete\')';		
    
    String diseaseKey;
    String filterCondition;
    public EligibilityVaccineMassRecalcBatch(String diseaseKey, String filterCondition){
        this.diseaseKey = diseaseKey;
        this.filterCondition = filterCondition;
    }

    public Database.QueryLocator start(Database.BatchableContext batchableContext) {
        if(this.filterCondition == null || this.filterCondition == '') { 	
            return Database.getQueryLocator(query);
        } else {
            return Database.getQueryLocator(query + ' AND ' + this.filterCondition);
        }
    }

    public void execute(Database.BatchableContext batchableContext, List<Case> scope)  {
        Map<ID, Case> cases = new Map<ID, Case>(scope);
        EligibilityVaccineRuleEngine handler = new EligibilityVaccineRuleEngine(diseaseKey).start();
        EligibilityVaccineRuleEngine.CandidateVaccineEvent records = handler.execute(cases.keySet());

        // capture all previously eligible cases
        List<Case> previouslyEligibleCases = new List<Case>();
        for(Case c : scope) {
            if(c.Eligibility_Status__c == 'Eligible') {
                previouslyEligibleCases.add(c);
            }
        }
            
        for (Candidate_Vaccine__c cv : records.toInsert) {
            Case thisCase = cases.get(cv.Vaccine_Application__c);

            cv.Account__c = thisCase.AccountId;
            thisCase.Site_Category__c = cv.Eligibility_Vaccine_Group__r.Site_Category__c;
            thisCase.Eligibility_Status__c = 'Eligible';
            thisCase.Eligibility_Vaccine_Group__c = cv.Eligibility_Vaccine_Group__c;
        }
        Database.delete(records.toDelete, false);
        Database.insert(records.toInsert, false);
        Database.update(cases.values(), false);
    }
    
    public void finish(Database.BatchableContext batchableContext){
        System.debug('Finish');
    }
}