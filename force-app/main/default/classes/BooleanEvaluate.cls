/**
 * @author: https://github.com/hsaraujo/BooleanEvaluate-Apex/blob/master/BooleanEvaluate.cls
 */

public with sharing class BooleanEvaluate {

    private static final String ANDv = 'AND';
    private static final String ORv = 'OR';
    private static final String OPEN = '(';
    private static final String CLOSE = ')';

    public String expression;
    private Boolean[] values;
    public String finalExpression;
    public Boolean finalResult = false;

    public BooleanEvaluate(String expression, Boolean[] values){
		this.values = values;
        this.expression = expression;
        this.formatExpression();
    }

    public void evaluate(){
   		evaluate(this.expression);
		System.debug('expression:'+this.expression);
        System.debug('finalexpression:'+this.finalExpression);
        this.finalResult = evaluateExpression(this.finalExpression);
        system.debug('finalresult:'+this.finalResult);
    }

    private void evaluate(String expression){

        if(!expression.contains(OPEN)){
            this.finalExpression = expression;
            return;
        }

        Integer indexOfOpen = -1;
        Integer indexOfClose = -1;

        String[] chars = expression.split('');
        for(Integer i = 0; i < chars.size(); i++){

            String singleChar = chars[i];

            if(singleChar == OPEN) {
                indexOfOpen = i;
                continue;
            }

            if(singleChar == CLOSE) {
                indexOfClose = i;
                break;
            }
        }

        String replace = expression.substring(indexOfOpen + 1 , indexOfClose);
        expression = expression.replace( OPEN + replace + CLOSE, String.valueOf( evaluateExpression(replace) ) );
        evaluate(expression);

    }

    public Boolean evaluateExpression(String expression){

        Boolean result = false;
        for( String conj : expression.split(ORv) ){

            Boolean b = true;
            for( String single : conj.split(ANDv) ){
                b &= Boolean.valueOf(single.trim());
            }

            result |= b;
        }

        return result;

    }

    private void formatExpression(){
        
        for (Integer i = this.values.size(); i > 0 ; i--){
            this.expression = this.expression.replace(String.valueOf(i), String.valueOf(this.values[i - 1]));
        }

        System.debug(this.expression);
    }
}