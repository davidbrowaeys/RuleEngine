/**
* @author David Browaeys
* @date 27/04/2021
* @group Eligibility Vaccine Engine
* @description Service class to handle eligibility vaccine calculation rule engine
*/
public without sharing class EligibilityVaccineRuleEngine {
    public static Boolean isLocked = false;
    public String diseaseKey;
    
    private String[] queryfields;
    private List<Candidate_Vaccine__c> candidateVaccines;
    private Map<String, Aggregation> aggregations;
    private Eligibility_Vaccine_Group__c[] rules;
    private Map<ID,Object> aggregateResults;
    private CandidateVaccineEvent vaccineEvent;
    private Map<Id, List<Candidate_Vaccine__c>> mapCase;

    public EligibilityVaccineRuleEngine(String diseaseKey){
        this.diseaseKey = diseaseKey;
        this.candidateVaccines = new List<Candidate_Vaccine__c>();
        this.aggregations = new Map<String, Aggregation>();
        this.queryfields = new List<String>();
        this.vaccineEvent = new CandidateVaccineEvent();
        this.mapCase = new Map<Id, List<Candidate_Vaccine__c>>();
    }
    public EligibilityVaccineRuleEngine start(){
        this.rules = getEligibilityGroupAndCriteria(diseaseKey);   //get Eligibility for specified record
        this.queryfields = parseFieldsToString(rules); //parse field reference in Eligibility crtieria into string
        return this;
    }
    public CandidateVaccineEvent execute(String recordId){
        return execute(new Set<ID>{recordId});
    }
    public CandidateVaccineEvent execute(Set<ID> recordIds){
        if (recordIds == null || recordIds.isEmpty() == true){
            throw new IllegalArgumentException('Record is mandatory to run this process');
        }

        // case where no groups are active
        if(this.rules.size() == 0) {
            return new CandidateVaccineEvent();
        }

        String soql = String.format('SELECT {0} FROM {1} WHERE Id IN :recordIds',
                                    new List<String>{
                                        String.join(queryfields,','), 
                                            getObjectApiName((ID)recordIds.iterator().next())});
        
        List<SObject> records = Database.query(soql);
        parseAggregateFunctionToSql(rules, recordIds); //perform sql for aggregate function on child records

        List<Candidate_Vaccine__c> candidates = [SELECT Id, Vaccine_Application__c, Name, Eligible_Vaccine__r.Name FROM Candidate_Vaccine__c WHERE Vaccine_Application__c =: recordIds];
        for(ID thisId : recordIds) {
            this.mapCase.put(thisId, new List<Candidate_Vaccine__c>());
        }

        for(Candidate_Vaccine__c candidate : candidates) {
            Id caseId = candidate.Vaccine_Application__c;
            this.mapCase.get(caseId).add(candidate);
        }

        for (Sobject record : records){
            eval(record);
        }
        vaccineEvent.toInsert = this.candidateVaccines;
        return vaccineEvent;
    }
    public String getObjectApiName(ID recordId){
        return recordId.getSObjectType().getDescribe().getName();
    }
    public void eval(SObject record){
		BooleanEvaluate boolEval =null;
        for (Eligibility_Vaccine_Group__c r : rules){
            List<String> criteriaEvaluated = new List<String>();
            Map<Integer, Boolean> criteriaResultsMap = new Map<Integer, Boolean>();
            for (Eligibility_Criteria__c c : r.Eligibility_Criteria__r){
                Boolean isValid = processRuleCriteria(c,record, aggregateResults);
                criteriaResultsMap.put(Integer.valueOf(c.Criteria_Number__c), isValid);
                if(r.Filter_Logic__c != 'Custom' && isValid ==  true){
                    criteriaEvaluated.add(c.Id);
                }
            }
            if (    (r.Filter_Logic__c == 'All' && criteriaEvaluated.size() == r.Eligibility_Criteria__r.size() ) ||
                    (r.Filter_Logic__c == 'Any' && criteriaEvaluated.size() >= 1 )||
                    (r.Filter_Logic__c == 'Custom' && criteriaResultsMap.size() >= 1 )){
                
                if (r.Filter_Logic__c == 'Custom'){
                    //start of evaluate expression
		            boolEval = new BooleanEvaluate(r.Custom_Filter_Expression__c, criteriaResultsMap.values());
                    boolEval.evaluate();
                    //end of evaluate expression
            	}
                
                if((boolEval!= null && r.Filter_Logic__c == 'Custom' && boolEval.finalResult) ||
                   (r.Filter_Logic__c == 'Any' || r.Filter_Logic__c == 'All')){    
                    addAllocatedVaccines(record, r);
                    break; //no need to eval next group
                }
            }
        }
    }
    private void addAllocatedVaccines(SObject record, Eligibility_Vaccine_Group__c r){
        Case c = (Case) record;
        List<String> currentBrands = new List<String>();
        List<Candidate_Vaccine__c> forCVdelete = new List<Candidate_Vaccine__c>();
        //evaluate if brands have changed
        for(Candidate_Vaccine__c cv : mapCase.get(c.Id)) {
            currentBrands.add(cv.Eligible_Vaccine__r.Name);
            forCVdelete.add(cv);
        }
        vaccineEvent.previousBrands.put(c.Id, String.join(currentBrands, ', '));

        List<String> newBrands = new List<String>();
        List<Candidate_Vaccine__c> forCVInsert = new List<Candidate_Vaccine__c>();
        for (Eligibility_Allocated_Vaccine__c eav : r.Allocated_Vaccines__r){            
            forCVInsert.add(
                new Candidate_Vaccine__c(
                    Vaccine_Application__c = record.Id,
                    Eligible_Vaccine__r = eav.Vaccine__r,
                    Eligible_Vaccine__c = eav.Vaccine__c,
                    Site_Category__c = r.Site_Category__c,
                    Eligibility_Vaccine_Group__r = r,
                    Eligibility_Vaccine_Group__c = r.Id
                )
            );
            newBrands.add(eav.Vaccine__r.Name);
        }

        // if the brand lists don't match, delete and insert
        Boolean replaceVacc = (currentBrands.size() != newBrands.size()); // replace if not the same size
        if(!replaceVacc) { // further comparison if same size, different elements
            for(String br : currentBrands) {
                replaceVacc |= !newBrands.contains(br);
            }
        }

        // replace
        if(replaceVacc) {
            this.candidateVaccines.addAll(forCVInsert);
            this.vaccineEvent.toDelete.addAll(forCVdelete);
        } 

        // record candidates for About Me invocation case (it's action is to delete all others and replace every time)
        this.vaccineEvent.candidates.addAll(forCVInsert);
    }
    /**
    * @author David Browaeys
    * @date 27/04/2021
    * @description This method return a list of Eligibility base on a specified category and record id
    * @param objectApiName Object Api Name
    * @param parentId id of the object record
    * @return list of Eligibilitys that meet the criteria
    */
    public Eligibility_Vaccine_Group__c[] getEligibilityGroupAndCriteria(String diseaseKey){
        return [SELECT  Id, Description__c, Filter_Logic__c, Custom_Filter_Expression__c, Site_Category__c,
                        (SELECT Id, Field_Name__c, Operator__c, Criteria_Value__c, Aggregate_Expression__c, Criteria_Number__c FROM Eligibility_Criteria__r ORDER BY Criteria_Number__c ASC),
                        (SELECT Id, Vaccine__c, Vaccine__r.Name FROM Allocated_Vaccines__r)
                FROM Eligibility_Vaccine_Group__c 
                WHERE Active__c = TRUE 
                //AND Disease__r.Exsternal_ID__c = :diseaseKey
                ORDER BY Sequence__c ASC NULLS LAST];
    }
    /**
    * @author David Browaeys
    * @date 27/04/2021
    * @description This method go to all the Eligibility crtieria and concert all fields referenced into a single string
    * @param rules list of Eligibilitys
    * @return single string containing all fields comma separated. 
    */
    public List<String> parseFieldsToString(List<Eligibility_Vaccine_Group__c> rules){
        List<String> fields = new List<String>();
        for (Eligibility_Vaccine_Group__c r : rules){
            for (Eligibility_Criteria__c c : r.Eligibility_Criteria__r){
                if (fields.contains(c.Field_Name__c) == false && c.Field_Name__c != 'aggregate') 
                    fields.add(c.Field_Name__c);
            }
        }
        return fields;
    }
    /**
    * @author David Browaeys
    * @date 27/04/2021
    * @description This method parse all Eligibility criteria that are set as aggregate function. Aggregate function are defined on the Eligibility_Crtieria__c.Aggregate_Expression__c. 
    *   Syntax: Aggregate|ChildObject|AggregateField|ParentField|Condition::EligibilityCriteriaValue
    *   Example: SUM|Drawdown__c|Amount__c|Opportunity__c|Amount__c > 10000
    * @param rules list of Eligibilitys
    * @param record id of the sobject record
    * @return map of calculated aggregate result by Eligibility criteria id
    */
    public void parseAggregateFunctionToSql(List<Eligibility_Vaccine_Group__c> rules, Set<ID> recordIds){
        retrieveAggregationFromCriteria(rules,recordIds);
        //perform SOQL for all aggregate functions(Eligibility crtieria). 
        //This soql into for loop is control on the front end by limiting the number of aggregate function per Eligibilitys.  
        for (Aggregation aggr : this.aggregations.values()){
            if (Limits.getQueries() < (Limits.getLimitQueries() - 10)){ //this will allow 90 aggregate function per object type
                List<SObject> result = Database.query(aggr.query);
                for (SObject res : result){
                    aggr.results.put((Id) res.get('recId'), res.get('result'));
                }
            }
        }
    }
    public void retrieveAggregationFromCriteria(List<Eligibility_Vaccine_Group__c> rules, Set<ID> recordIds){
        //interprete all the Eligibility crtieria for aggregate function and transform them into soql query
        for (Eligibility_Vaccine_Group__c r : rules){
            try{
                for (Eligibility_Criteria__c c : r.Eligibility_Criteria__r){
                    if (c.Field_Name__c.toLowerCase() == 'aggregate'){ 
                        if (this.aggregations.get(c.Aggregate_Expression__c) == null){
                            Aggregation aggr = new Aggregation(c.Aggregate_Expression__c);
                            //Quoting the merge field makes it literal text. In order to get the merge field to work, you have to quote the quotes
                            aggr.query = String.format('SELECT {3} recId, {0}({2})result FROM {1} WHERE {3} IN :recordIds {4} GROUP BY {3}',
                                                       new String[]{
                                                            aggr.aggregateFunction,
                                                            aggr.childObjectName,
                                                            aggr.aggregateField,
                                                            aggr.parentField,
                                                            aggr.condition
                                                       });
                            this.aggregations.put(c.Aggregate_Expression__c, aggr);
                        }
                        break;      //make sure we have only one SOQL per Eligibility Group
                    }
                }   
            }catch(Exception e){
                System.debug('Error for parsing aggregate function. Eligibility will be ignored!');
            }
        }
    }
    /**
    * @author David Browaeys
    * @date 27/04/2021
    * @description Evaluate all Eligibility criteria for a specified record
    * @param crteria Eligibility criteria to evaluate
    * @param record instance of an sobject
    * @param aggregateResults map of aggregation
    * @return true if crtieria was evaluate successfully otherwise false
    */
    public Boolean processRuleCriteria(Eligibility_Criteria__c criteria, SObject record, Map<ID,Object> aggregateResults){
        Object leftValue;
        String rightValue;
        if (criteria.Field_Name__c.toLowerCase() == 'aggregate'){
            if (this.aggregations.get(criteria.Aggregate_Expression__c) != null){ 
                rightValue = criteria.Criteria_Value__c;
                leftValue = this.aggregations.get(criteria.Aggregate_Expression__c).results.get(record.Id);
                if (leftValue == null){ //need this ?
                    leftValue = 0;
                }
            }else{
                return false;
            }
        }else{
            leftValue = getFieldValue(record, criteria.Field_Name__c.split('\\.'), 0);  //this is to cover cross object Opportunity.Account.Customer_Number__c
            rightValue = criteria.Criteria_Value__c;
        }
        switch on criteria.Operator__c {
            when 'equals' {
                return isequals(leftValue,rightValue);
            }when 'not equals' {
                return isnotequals(leftValue,rightValue);
            }when 'contains' {
                List<String> rightValues = rightValue.split('[\\;\\,\\|]');
                Boolean containsMatch = false;
                for(String rv : rightValues) {
                    containsMatch |= (leftValue != null && ((String)leftValue).contains(rv));
                }

                return containsMatch;
            }when 'not contains' {
                return leftValue != null && ((String)leftValue).contains(rightValue) == false;
            }when 'includes' {
                return leftValue != null && ((String)leftValue).split('[\\;\\,\\|]').contains(rightValue) == true;
            }when 'not includes' {
                return rightValue != null && ((String)rightValue).split('[\\;\\,\\|]').contains(rightValue) == false;
            }when 'greater' {
                return isgreaterthan(leftValue,rightValue);
            }when 'greater or equals' {
                return isgreaterorequalsthan(leftValue,rightValue);
            }when 'less' {
                return issmallerthan(leftValue,rightValue);
            }when 'less or equals' {
                return issmallerorequalsthan(leftValue,rightValue);
            }when else {
                return false;
            }
        }
    }
    /**
    * @author David Browaeys
    * @date 27/04/2021
    * @description Recursive method that retrieve object value of a specified field name, this handle cross object such as Opportunity.Account.Custom_Number__c
    * @param record instance of an sobject
    * @param fieldNames apiname of fields starting from direct parent(Opportunity) to field name(Customer_Number__c)
    * @param index current index of the field name list
    * @return untyped value of a field 
    */
    public Object getFieldValue(SObject record, String[] fieldNames, Integer index){
        if (record == null){
            return null;
        }
        if (index == fieldNames.size() - 1){
            return record.get(fieldNames[index]);
        }
        return getFieldValue(record.getSObject(fieldNames[index]),fieldNames, index + 1);
    }
    public Boolean isnotequals(Object o, String p){
        if(o instanceof Date)               return (Date) o != (p != null ? parseDate(p) : null);
        if(o instanceof Datetime)           return (Datetime) o != (p != null ? parseDatetime(p) : null);
        if(o instanceof Integer)            return (Integer) o != (p != null ? Integer.valueOf(p) : null);
        if(o instanceof Decimal)            return (Double) o != (p != null ? Double.valueOf(p) : null);
        if(o instanceof Double)             return (Double) o != (p != null ? Double.valueOf(p) : null);
        return (String) o != p;
    }
    public Boolean isequals(Object o, String p){
        system.debug('***instance '+o+'-'+p);
        if(o instanceof Date)               return (Date) o == (p != null ? parseDate(p) : null);
        if(o instanceof Datetime)           return (Datetime) o == (p != null ? parseDatetime(p) : null);
        if(o instanceof Integer)            return (Integer) o == (p != null ? Integer.valueOf(p) : null);
        if(o instanceof Decimal)            return (Double) o == (p != null ? Double.valueOf(p) : null);
        if(o instanceof Double)             return (Double) o == (p != null ? Double.valueOf(p) : null);
        return (String) o == p;
    }
    /**
    * @author David Browaeys
    * @date 27/04/2021
    * @description Compare if an entity is smaller than another entity
    * @param o left entity to compare
    * @param p right entity to compare
    * @return true is left entity is smaller than right entity 
    */
    public Boolean issmallerthan(Object o, String p){
        if(o instanceof Date)               return (Date) o < (p != null ? parseDate(p) : null);
        if(o instanceof Datetime)           return (Datetime) o < (p != null ? parseDatetime(p) : null);
        if(o instanceof Integer)            return (Integer) o < (p != null ? Integer.valueOf(p) : null);
        if(o instanceof Decimal)            return (Double) o < (p != null ? Double.valueOf(p) : null);
        if(o instanceof Double)             return (Double) o < (p != null ? Double.valueOf(p) : null);
        return false;
    }
    /**
    * @author David Browaeys
    * @date 27/04/2021
    * @description Compare if an entity is smaller than another entity
    * @param o left entity to compare
    * @param p right entity to compare
    * @return true is left entity is smaller or equals than right entity 
    */
    public Boolean issmallerorequalsthan(Object o, String p){
        if(o instanceof Date)               return (Date) o <= (p != null ? parseDate(p) : null);
        if(o instanceof Datetime)           return (Datetime) o <= (p != null ? parseDatetime(p) : null);
        if(o instanceof Integer)            return (Integer) o <= (p != null ? Integer.valueOf(p) : null);
        if(o instanceof Decimal)            return (Double) o <= (p != null ? Double.valueOf(p) : null);
        if(o instanceof Double)             return (Double) o <= (p != null ? Double.valueOf(p) : null);
        return false;
    }/**
    * @author David Browaeys
    * @date 27/04/2021
    * @description Compare if an entity is greater or equals than another entity
    * @param o left entity to compare
    * @param p right entity to compare
    * @return true is left entity is greater or equals than right entity 
    */
    public Boolean isgreaterorequalsthan(Object o, String p){
        if(o instanceof Date)               return (Date) o >= (p != null ? parseDate(p) : null);
        if(o instanceof Datetime)           return (Datetime) o >= (p != null ? parseDatetime(p) : null);
        if(o instanceof Integer)            return (Integer) o >= (p != null ? Integer.valueOf(p) : null);
        if(o instanceof Decimal)            return (Double) o >= (p != null ? Double.valueOf(p) : null);
        if(o instanceof Double)             return (Double) o >= (p != null ? Double.valueOf(p) : null);
        return false;
    }
    /**
    * @author David Browaeys
    * @date 27/04/2021
    * @description Compare if an entity is greater than another entity
    * @param o left entity to compare
    * @param p right entity to compare
    * @return true is left entity is greater than right entity 
    */
    public Boolean isgreaterthan(Object o, String p){
        if(o instanceof Date)               return (Date) o > (p != null ? parseDate(p) : null);
        if(o instanceof Datetime)           return (Datetime) o > (p != null ? parseDatetime(p) : null);
        if(o instanceof Integer)            return (Integer) o > (p != null ? Integer.valueOf(p) : null);
        if(o instanceof Decimal)            return (Double) o > Double.valueOf(p);
        if(o instanceof Double)             return (Double) o > Double.valueOf(p);
        return false;
    }
    /**
    * @author David Browaeys
    * @date 27/04/2021
    * @description This method parse a date string formula into a date based on well defined syntax. 
    * @usage 
    * Date mydate1 = parseDate('TODAY|Y+2');
    * Date mydate2 = parseDate('TODAY|M-2');
    * Date mydate3 = parseDate('THIS_WEEK|D-2');
    * Date mydate4 = parseDate('THIS_MONTH|M+2');
    * @param s string date
    * @return converted date
    */
    public Date parseDate(String s){
        Date targetDate;
        switch on s.substring(0,s.indexOf('|') >= 0 ? s.indexOf('|') : s.length()){
            when 'TODAY' {
                targetDate = Date.today();
            } when 'THIS_MONTH' {
                targetDate = Date.today().toStartOfMonth();
            } when 'THIS_WEEK'{
                targetDate = Date.today().toStartOfWeek();
            } when else{
                System.debug('No date format');
            }
        }
        if (targetDate != null && s.indexOf('|') >= 0){
            String offset = s.substring(s.indexOf('|') + 1);
            switch on offset.substring(0,1) {
                when 'd' {
                    offset = offset.removeStart('d'); 
                    targetDate = targetDate.addDays(Integer.valueOf(offset));
                } when 'm' {
                    offset = offset.removeStart('m'); 
                    targetDate = targetDate.addMonths(Integer.valueOf(offset));
                } when 'y' {
                    offset = offset.removeStart('y'); 
                    targetDate = targetDate.addDays(Integer.valueOf(offset));
                } when else {
                    throw new IllegalArgumentException('Unsupported Date Format');
                }
            } 
        }
        return targetDate != null ? targetDate : Date.valueOf(s);
    }
    /**
    * @author David Browaeys
    * @date 27/04/2021
    * @description This method parse a datetime string formula into a datetime based on well defined syntax. 
    * @usage 
    * Datetime mydate1 = parseDatetime('NOW|hh+2');
    * Datetime mydate2 = parseDatetime('NOW|mm-30');
    * @param s string datetime
    * @return converted datetime
    */
    public Datetime parseDatetime(String s){
        Datetime targetDate;
        switch on s.substring(0,s.indexOf('|') >= 0 ? s.indexOf('|') : s.length()){
            when 'NOW' {
                targetDate = Datetime.now();
            } when else{
                System.debug('No datetime format');
            }
        }
        if (targetDate != null && s.indexOf('|') >= 0){
            String offset = s.substring(s.indexOf('|') + 1);
            switch on offset.substring(0,1) {
                when 'd' {
                    offset = offset.removeStart('d'); 
                    targetDate = targetDate.addDays(Integer.valueOf(offset));
                } when 'm' {
                    offset = offset.removeStart('m'); 
                    targetDate = targetDate.addMonths(Integer.valueOf(offset));
                } when 'y' {
                    offset = offset.removeStart('y'); 
                    targetDate = targetDate.addDays(Integer.valueOf(offset));
                } when 'H' {
                    offset = offset.removeStart('H'); 
                    targetDate = targetDate.addHours(Integer.valueOf(offset));
                } when 'M' {
                    offset = offset.removeStart('M'); 
                    targetDate = targetDate.addMinutes(Integer.valueOf(offset));
                } when else {
                    System.debug('Unsupported Datetime Format');
                }
            } 
        }
        return targetDate != null ? targetDate : Datetime.valueOf(s);
    }

    public class Aggregation{
        String aggregateFunction;
        String childObjectName;
        String aggregateField;
        String parentField;
        String condition;
        String query;
        Map<ID, Object> results;
        public Aggregation(String aggregateExpression){
            this.results = new Map<ID,Object>();
            String[] attributes = aggregateExpression.split('\\|');//aggregate function separator
            if (attributes.size() == 4 ) attributes.add('');    //4th attributes means there is no where condition
            else attributes[4] = 'AND '+attributes[4];

            this.aggregateFunction = attributes[0];
            this.childObjectName = attributes[1];
            this.aggregateField = attributes[2];
            this.parentField = attributes[3];
            this.condition = attributes[4];
        }
    }

    public class CandidateVaccineEvent{
        public List<Candidate_Vaccine__c> toInsert;
        public List<Candidate_Vaccine__c> toDelete;
        public List<Candidate_Vaccine__c> candidates; // list that they are eligible for, regardless of whether they should be inserted
        public Map<Id, String> previousBrands;

        public CandidateVaccineEvent() {
            previousBrands = new Map<Id, String>();
            toDelete = new List<Candidate_Vaccine__c>();
            candidates = new List<Candidate_Vaccine__c>();
        }
    }
}