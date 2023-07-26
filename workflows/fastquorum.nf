/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    VALIDATE INPUTS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

def summary_params = NfcoreSchema.paramsSummaryMap(workflow, params)

// Validate input parameters
WorkflowFgcons.initialise(params, log)

// TODO nf-core: Add all file path parameters for the pipeline to the list below
// Check input path parameters to see if they exist
def checkPathParamList = [ params.input, params.multiqc_config, params.ref_fasta ]
for (param in checkPathParamList) { if (param) { file(param, checkIfExists: true) } }

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Check mandatory parameters
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

if (params.input) { ch_input = file(params.input) } else { exit 1, 'Input samplesheet not specified!' }
if (params.ref_fasta) { ch_ref_fasta = Channel.fromPath(params.ref_fasta).collect() } else {
  log.error "No reference FASTA was specified (--ref_fasta)."
  exit 1
}

// The index directory is the directory that contains the FASTA
ch_ref_index_dir = ch_ref_fasta.map { it -> it.parent }

// Set various consensus calling and filtering parameters if not given
if (params.duplex_seq) {
  if (!params.groupreadsbyumi_strategy) { groupreadsbyumi_strategy = 'Paired' }
  else if (params.groupreadsbyumi_strategy != 'Paired') {
    log.error "config groupreadsbyumi_strategy must be 'Paired' for duplex-sequencing data"
    exit 1
  }
  if (!params.call_min_reads) { call_min_reads = '1 1 0' } else { call_min_reads = params.call_min_reads }
  if (!params.filter_min_reads) { filter_min_reads = '3 1 1' } else { filter_min_reads = params.filter_min_reads }
} else {
  if (!params.groupreadsbyumi_strategy) { groupreadsbyumi_strategy = 'Adjacency' }
  else if (params.groupreadsbyumi_strategy == 'Paired') {
    log.error "config groupreadsbyumi_strategy cannot be 'Paired' for non-duplex-sequencing data"
    exit 1
  } else {
	  groupreadsbyumi_strategy = params.groupreadsbyumi_strategy
  }
  if (!params.call_min_reads) { call_min_reads = '1' } else { call_min_reads = params.call_min_reads }
  if (!params.filter_min_reads) { filter_min_reads = '3' } else { filter_min_reads = params.filter_min_reads }
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    CONFIG FILES
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

ch_multiqc_config        = file("$projectDir/assets/multiqc_config.yml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config) : Channel.empty()

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT LOCAL MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
//
include { INPUT_CHECK } from '../subworkflows/local/input_check'
include { ALIGN_BAM                         as ALIGN_RAW_BAM               } from '../modules/local/align_bam/main'
include { ALIGN_BAM                         as ALIGN_CONSENSUS_BAM         } from '../modules/local/align_bam/main'
include { FGBIO_FASTQTOBAM                  as FASTQTOBAM                  } from '../modules/local/fgbio/fastqtobam/main'
include { FGBIO_GROUPREADSBYUMI             as GROUPREADSBYUMI             } from '../modules/local/fgbio/groupreadsbyumi/main'
include { FGBIO_CALLMOLECULARCONSENSUSREADS as CALLMOLECULARCONSENSUSREADS } from '../modules/local/fgbio/callmolecularconsensusreads/main'
include { FGBIO_CALLDDUPLEXCONSENSUSREADS   as CALLDDUPLEXCONSENSUSREADS   } from '../modules/local/fgbio/callduplexconsensusreads/main'
include { FGBIO_FILTERCONSENSUSREADS        as FILTERCONSENSUSREADS        } from '../modules/local/fgbio/filterconsensusreads/main'
include { FGBIO_COLLECTDUPLEXSEQMETRICS     as COLLECTDUPLEXSEQMETRICS     } from '../modules/local/fgbio/collectduplexseqmetrics/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

//
// MODULE: Installed directly from nf-core/modules
//
include { FASTQC                      } from '../modules/nf-core/modules/fastqc/main'
include { MULTIQC                     } from '../modules/nf-core/modules/multiqc/main'
include { CUSTOM_DUMPSOFTWAREVERSIONS } from '../modules/nf-core/modules/custom/dumpsoftwareversions/main'

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    RUN MAIN WORKFLOW
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

// Info required for completion email and summary
def multiqc_report = []

workflow FASTQUORUM {

    ch_versions = Channel.empty()

    //
    // SUBWORKFLOW: Read in samplesheet, validate and stage input files
    //
    INPUT_CHECK (
        ch_input
    )
    ch_versions = ch_versions.mix(INPUT_CHECK.out.versions)

    //
    // MODULE: Run FastQC
    //
    FASTQC (
        INPUT_CHECK.out.reads
    )
    ch_versions = ch_versions.mix(FASTQC.out.versions.first())

    //
    // MODULE: Run fgbio FastqToBam
    //
    FASTQTOBAM(INPUT_CHECK.out.reads)
    ch_versions = ch_versions.mix(FASTQTOBAM.out.versions.first())

    //
    // MODULE: Align with bwa mem
    //
    grouped_sort = true
    ALIGN_RAW_BAM(FASTQTOBAM.out.bam, ch_ref_index_dir, grouped_sort)
    ch_versions = ch_versions.mix(ALIGN_RAW_BAM.out.versions)

    //
    // MODULE: Run fgbio GroupReadsByUmi
    //
    GROUPREADSBYUMI(ALIGN_RAW_BAM.out.bam, groupreadsbyumi_strategy, params.groupreadsbyumi_edits)
    ch_versions = ch_versions.mix(GROUPREADSBYUMI.out.versions.first())

    // TODO: duplex_seq can be inferred from the read structure, but that's out of scope for now
    if (params.duplex_seq) {
        //
        // MODULE: Run fgbio CallDuplexConsensusReads
        //
        CALLDDUPLEXCONSENSUSREADS(GROUPREADSBYUMI.out.bam, call_min_reads, params.call_min_baseq)
        ch_versions = ch_versions.mix(CALLDDUPLEXCONSENSUSREADS.out.versions.first())

        //
        // MODULE: Run fgbio CollecDuplexSeqMetrics
        //
        COLLECTDUPLEXSEQMETRICS(GROUPREADSBYUMI.out.bam)
        ch_versions = ch_versions.mix(COLLECTDUPLEXSEQMETRICS.out.versions.first())

        // Add the consensus BAM to the channel for downstream processing
        CALLDDUPLEXCONSENSUSREADS.out.bam.set { ch_consensus_bam }
        ch_versions = ch_versions.mix(CALLDDUPLEXCONSENSUSREADS.out.versions.first())

    } else {
        //
        // MODULE: Run fgbio CallMolecularConsensusReads
        //
        CALLMOLECULARCONSENSUSREADS(GROUPREADSBYUMI.out.bam, call_min_reads, params.call_min_baseq)
        ch_versions = ch_versions.mix(CALLMOLECULARCONSENSUSREADS.out.versions.first())

        // Add the consensus BAM to the channel for downstream processing
        CALLMOLECULARCONSENSUSREADS.out.bam.set { ch_consensus_bam }
    }

    //
    // MODULE: Align with bwa mem
    //
    ALIGN_CONSENSUS_BAM(ch_consensus_bam, ch_ref_index_dir, false)
    ch_versions = ch_versions.mix(ALIGN_CONSENSUS_BAM.out.versions.first())

    //
    // MODULE: Run fgbio FilterConsensusReads
    //
    FILTERCONSENSUSREADS(ALIGN_CONSENSUS_BAM.out.bam, ch_ref_fasta, filter_min_reads, params.filter_min_baseq, params.filter_max_base_error_rate)
    ch_versions = ch_versions.mix(FILTERCONSENSUSREADS.out.versions.first())

    CUSTOM_DUMPSOFTWAREVERSIONS (
        ch_versions.unique().collectFile(name: 'collated_versions.yml')
    )

    //
    // MODULE: MultiQC
    //
    workflow_summary    = WorkflowFgcons.paramsSummaryMultiqc(workflow, summary_params)
    ch_workflow_summary = Channel.value(workflow_summary)

    ch_multiqc_files = Channel.empty()
    ch_multiqc_files = ch_multiqc_files.mix(Channel.from(ch_multiqc_config))
    ch_multiqc_files = ch_multiqc_files.mix(ch_multiqc_custom_config.collect().ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(ch_workflow_summary.collectFile(name: 'workflow_summary_mqc.yaml'))
    ch_multiqc_files = ch_multiqc_files.mix(CUSTOM_DUMPSOFTWAREVERSIONS.out.mqc_yml.collect())
    ch_multiqc_files = ch_multiqc_files.mix(FASTQC.out.zip.collect{it[1]}.ifEmpty([]))
    ch_multiqc_files = ch_multiqc_files.mix(GROUPREADSBYUMI.out.histogram.map{it[1]}.collect())

    MULTIQC (
        ch_multiqc_files.collect()
    )
    multiqc_report = MULTIQC.out.report.toList()
    ch_versions    = ch_versions.mix(MULTIQC.out.versions)
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    COMPLETION EMAIL AND SUMMARY
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/

workflow.onComplete {
    if (params.email || params.email_on_fail) {
        NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    }
    NfcoreTemplate.summary(workflow, params, log)
}

/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    THE END
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
*/
