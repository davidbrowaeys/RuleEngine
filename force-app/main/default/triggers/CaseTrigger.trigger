trigger CaseTrigger on Case (after update) {
    if (EligibilityVaccineRuleEngine.isLocked == true){
        return;
    }
    if (Trigger.isAfter && Trigger.isUpdate){
        Case[] toUpdate = new Case[0];
        EligibilityVaccineRuleEngine.CandidateVaccineEvent cve = new EligibilityVaccineRuleEngine('COVID19').start().execute(Trigger.newMap.keySet());
        List<Candidate_Vaccine__c> candidates = cve.candidates;
        insert candidates;
        for  (Candidate_Vaccine__c cv : candidates){
            toUpdate.add(new Case(Id = cv.Vaccine_Application__c, Eligibility_Status__c = 'Eligible'));
        }
        EligibilityVaccineRuleEngine.isLocked = true;
        update toUpdate;
        EligibilityVaccineRuleEngine.isLocked = false;
    }
}