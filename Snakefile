import sys, os, csv
include: 'species.py'

if not 'species' in config:
    sys.exit("You must specify a 'species' parameter in your config file")    

species = config['species']
if not species in species_dict:
    sys.exit("The species '" + species + "' does not appear in the species.py file")

fasta_url = species_dict[species]	
SRA_ids = []

paired_end = True

if 'use_paired_end' in config:
    paired_end = bool(config['use_paired_end'])

directory = '.'
if 'directory' in config:
    directory = config['directory']

if not 'design_file' in config:
    sys.exit("You must specify the name of your 'design_file' in your config file")  

design_file = config['design_file']

kmer_size = 31
if 'kmer-size' in config:
    kmer_size = int(config['kmer-size'])

bootstrap_samples = 30
if 'bootstrap_samples' in config:
    bootstrap_samples = int(config['bootstrap_samples'])

bias = True
if 'bias' in config:
    bias = bool(config['bias'])

num_threads = 1
if 'threads' in config:
    num_threads = int(config['threads'])

index = -1
with open(design_file) as tsv:
    for line in csv.reader(tsv, delimiter='\t'):
        if line:
            if len(line) == 1:
                line = line[0].strip().split()  
            if index == -1:
                if 'Run_s' in line:
                    index = line.index('Run_s')
                elif 'run' in line:
                    index = line.index('run')
                else:
                    sys.exit("Your study design file must have a column named 'Run_s' or 'run'")
            else:
               SRA_ids.append(line[index])

if not os.path.exists(directory):
    os.makedirs(directory)

fasta = fasta_url.split('/')
fasta = fasta[len(fasta) - 1]
index = fasta.find(".fa")

if index == -1:
    print("'" + fasta + "' does not have a .fa extension")
    sys.exit(1)

base = fasta[0:index]

kidx = base + ".kidx"

index_path = 'indices/' + species + '/' + str(kmer_size) + '/'

kallisto_index_shell =  'mkdir -p ' + index_path + ' && cd $_ && ' 
kallisto_index_shell += 'kallisto index -k ' + str(kmer_size) + ' '
kallisto_index_shell += '-i ' + kidx + ' ../../../transcriptome/{base}.fa'

get_fasta_shell = 'cd transcriptome && wget -O ' + fasta + ' ' + fasta_url + ' '
if ".gz" in fasta:
    get_fasta_shell += '&& gunzip ' + fasta

sd = -1
fraglength = -1

kallisto_quant_shell = 'kallisto quant -i ' + index_path + kidx + ' '
if bias:
    kallisto_quant_shell += ' --bias '
if bootstrap_samples > 0:
    kallisto_quant_shell += ' -b ' + str(bootstrap_samples) + ' '

if not paired_end:
    if not 'sd' in config:
        sys.exit("For single end reads, you must specify an estimate standard deviation in the config file")
    if not 'fragment-length' in config:
        sys.exit("For single end reads, you must specify an estimate fragment length in the config file")
    sd = config['sd']
    fraglength = config['fragment-length']
    kallisto_quant_shell += '--single -l ' + str(fraglength) + ' -s ' + str(sd) + ' '

all_shell = ''
full_model = ''
reduced_model = ''

if 'full_model' in config:
    full_model = config['full_model']
    if 'reduced_model' in config:
        reduced_model = config['reduced_model']
        if 'use_genes' in config and bool(config['use_genes']):
            if not species in gene_anno_dict:
                sys.exit("You specified to use gene annotations but your species does not appear in the ensembl gene annotation database")
            all_shell = 'Rscript sleuth.R {directory} {design_file} {full_model} {reduced_model} ' + gene_anno_dict[species]
        else:
            all_shell = 'Rscript sleuth.R {directory} {design_file} {full_model} {reduced_model}'
    else:
        print("You must specify a 'reduced_model' parameeter for sleuth to run")
else:
    print("You must specify a 'full_model' parameter for sleuth to run")

rule sleuth:
    input:
        expand('{i}{k}', i = index_path, k = kidx),
        expand('{d}/results/{s}/kallisto/abundance.h5', s = SRA_ids, d = directory)
    output:
        directory + '/so.rds'
    shell:
        all_shell

rule deploy:
    input:
        directory + '/so.rds'
    shell:
        'python deploy_file.py ' + directory + '/'

rule get_transcriptome:
    output:
        expand('transcriptome/{f}', f = base + ".fa")
    shell:
        get_fasta_shell

rule index:
    input:
        expand('transcriptome/{f}', f = base + ".fa")
    output:
        index_path + kidx
    shell:
        kallisto_index_shell

if paired_end:
    rule kallisto:
        input:
            directory + '/results/{s}/{s}_1.fastq.gz',
            directory + '/results/{s}/{s}_2.fastq.gz',
            index_path + kidx
        output:
            directory + '/results/{s}/kallisto',
            directory + '/results/{s}/kallisto/abundance.h5'
        threads: num_threads
        shell:
            kallisto_quant_shell + 
            '-o {output[0]} '
            '-t {threads} '
            '{input[0]} {input[1]}'

    rule fastq_dump:
        output:
            directory + '/results/{s}/{s}_1.fastq.gz',
            directory + '/results/{s}/{s}_2.fastq.gz'
        threads: 1
        shell:
            'cd {directory} && '
            'fastq-dump '
            '--split-files '
            '-O results/{wildcards.s} '
            '--gzip '
            '{wildcards.s}'
else:
    rule kallisto:
        input:
            directory + '/results/{s}/{s}.fastq.gz',
            index_path + kidx
        output:
            directory + '/results/{s}/kallisto',
            directory + '/results/{s}/kallisto/abundance.h5'
        threads: num_threads
        shell:
            kallisto_quant_shell + 
            '-o {output[0]} '
            '-t {threads} '
            '{input[0]} '

    rule fastq_dump:
        output:
            directory + '/results/{s}/{s}.fastq.gz',
        threads: 1
        shell:
            'cd {directory} && '
            'fastq-dump '
            '-O results/{wildcards.s} '
            '--gzip '
            '{wildcards.s}'

rule clean:
    shell:
        'cd {directory} && '
        'rm -rf results/*/kallisto && '
        'rm -rf so.rds app.R '

	
