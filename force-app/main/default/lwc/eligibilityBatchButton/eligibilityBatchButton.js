import { LightningElement, api, wire, track} from 'lwc';
import runEligibilityBatchProcess from '@salesforce/apex/EligibilityProcessController.runEligibilityBatchProcess';
import trackEligibilityBatchProcess from '@salesforce/apex/EligibilityProcessController.trackEligibilityBatchProcess';
import { getRecord } from 'lightning/uiRecordApi';

export default class EligibilityBatchButton extends LightningElement {

    // get recordId of page
    @api recordId;

    // get the disease associated with the case
    disease;
    @wire(getRecord, { recordId: '$recordId', fields: ['Eligibility_Vaccine_Group__c.Disease__c'] })
    eligibilityVaccineGroupRecord({ error, data }) {
        if (data) {
            this.disease = data.fields.Disease__c.value;
            console.log(this.disease);
        } else if (error) {
            this.showError(error.body);
        }
    }

    // modal states
    isModalOpen = false;
    processRunning = false;
    errorState = false;
    errorMessage = '';

    // batch information
    batchId = '';
    batchProgress = 0;
    batchStatus = 'Holding';
    batchSize = 2000;
    filterCondition = "";
    
    // batch tracking
    interval = null;
    trackingInProgress = false;

    // constants
    BATCH_TRACK_INTERVAL = 5000;
    COMPLETION_MODAL_CLOSE_DELAY = 1000;

    // resets the modal states
    reset() {
        this.isModalOpen = false;
        this.processRunning = false;
        this.batchId = '';
        this.batchProgress = 0;
        this.batchStatus = 'Holding';
        this.errorState = false;
        this.errorMessage = '';
        this.trackingInProgress = false;
    }

    // dynamic label for the run batch button
    get recalculateButtonLabel() {
        if(this.processRunning) {
            return 'Status: ' + this.batchStatus;
        } else {
            return 'Recalculate';
        }
    }

    // dynamic status for disabling the ok button
    get okButtonDisableStatus() {
        return this.errorState || this.processRunning;
    }

    // open modal onclick
    openModal(event) {        
        this.isModalOpen = this.isBatchSizeValid(); // open if valid batch size
    }

    // close modal onclick
    closeModal(event) {
        this.isModalOpen = false;
        if(this.errorState) {
            this.reset();
        }
    }

    // cancel button onclick
    cancelButtonClick(event) {
        if(!this.processRunning) {
            this.reset();
        }
    }

    // ok button onclick
    okButtonClick(event) {
        // run the batch process
        this.processRunning = true;
        runEligibilityBatchProcess({disease: this.disease, batchSize: this.batchSize, filterCondition: this.filterCondition})
            .then(result => {
                this.batchId = result;
                console.log('BatchID: ' + this.batchId);
                this.startBatchTracking();
            })
            .catch(error => {
                this.showError(error.body);
            });
    }

    // batch size input value changed
    batchSizeChange(event) {
        this.batchSize = Number(event.target.value);
    }

    // optional filter input value changed
    filterConditionChange(event) {
        this.filterCondition = event.target.value;
    }

    // check if batch size input is valid
    isBatchSizeValid() {
        return (Number.isInteger(this.batchSize) && this.batchSize >= 1);
    }

    // start 'tracking' the batch, i.e. periodically retrieve progress
    startBatchTracking() {
        this.trackBatch();
        if(this.processRunning) {
            this.interval = setInterval(this.trackBatch.bind(this), this.BATCH_TRACK_INTERVAL);
        }
    }

    // retrieve batch progress
    trackBatch() {
        if(this.interval && !this.processRunning) {
            // stop the tracking interval
            clearInterval(this.interval);
        } else {
            if(!this.trackingInProgress) {
                this.trackingInProgress = true;
                trackEligibilityBatchProcess({batchId: this.batchId})
                    .then(job => {
                        this.batchStatus = job.Status;

                        if(job.NumberOfErrors > 0) {
                            // if one of the jobs had an error, stop tracking and display error
                            this.showError(job.ExtendedStatus);
                        } else {
                            // handle different job statuses
                            if(job.Status === 'Processing') {
                                this.batchProgress = job.JobItemsProcessed / job.TotalJobItems * 100;
                            } else if(job.Status === 'Completed') {
                                this.batchProgress = 100;
                                this.closeModalWithDelay();
                            } else if(job.Status === 'Aborted' || job.Status === 'Failed') {
                                this.showError("Error: Job ended with status '" + job.Status + "'");
                            }
                        }

                        this.trackingInProgress = false;
                    })
                    .catch(error => {
                        this.showError(error.body);
                    });
            } else {
                // skip progress request if previous one has not yet returned 
                console.log("Batch tracking skipped, BATCH_TRACK_INTERVAL (" + this.BATCH_TRACK_INTERVAL + "ms) too short");
            }
        }
    }

    // set modal to error state and stop current tracking process
    showError(error) {
        console.error(error);

        this.processRunning = false;
        this.errorState = true;
        this.errorMessage = error;
    }

    // close the modal after a delay (used when process finishes)
    closeModalWithDelay() {
        setTimeout(function() {
            this.reset();
        }.bind(this), this.COMPLETION_MODAL_CLOSE_DELAY);
    }

}