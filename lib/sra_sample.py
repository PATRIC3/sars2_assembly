#
# Wrapper to hold state etc for a SRA sample.
#

from pathlib import Path
import glob
import os
import sys
import subprocess
import threading
import threadlog

def read_defs_from_file(def_file, base_dir):
    #
    # Read our SRA defs to find the inputs needed. Stuff them into input queue.
    #
    defs = []
    with open(def_file) as fh:
        idx = 1
        for line in fh:
            cols = line.rstrip().split("\t")
            id = cols[0]

            sra = SraSample(id, idx, base_dir)

            if not sra.has_output_with_suffix("fasta"):
                defs.append(sra)

            idx += 1

    return defs


class SraSample:

    fastq_tmp = "/tmp"

    def __init__(self, id, idx, base_dir):
        self.base_dir = base_dir
        
        self.id = id
        self.idx = idx
        self.id_prefix = id[0:7]
        
        self.path = Path(base_dir, self.id_prefix, id)

    def create_out_dir(self):

        os.makedirs(self.path, exist_ok=True)

    def has_output_with_suffix(self, suffix):
        path = self.path / f"{self.id}.{suffix}"
        return path.exists()
        
    def metadata_file(self):
        return self.md_cache / f"{self.id}.json"

    def download(self):
        """ Download data if necessary.

        If the path contains .fastq files, just return those, along with False for the delete fastq flag.
        If the path contains a .sra file, use fasterq-dump to pull fastq files and place in TMPDIR.
        We return True for the delete fastq flag here.
        For now we don't actually do the SRA download.
        """

        me = threading.current_thread().name
        print(f"sample me={me}")

        out_fh = threadlog.get_logger()
        if not out_fh:
            out_fh = sys.stdout

        fq_files = self.find_fq_files()

        if fq_files is not None:
            return fq_files, False
            
        sra = self.path / f"{self.id}.sra"

        if sra.exists():
            print(f"load from {sra}", file=out_fh)

            if self.max_fasterq > 0:
                self.fasterq_semaphore.acquire()

            subprocess.run(["df", "-h"], stdout=out_fh)
            cmd = ["fasterq-dump",
                   "-o", f"{self.id}.fastq",
                   "-O", str(self.path),
                   "--split-files",
                   "-t", self.fastq_tmp,
                   str(sra)
                   ]
            print(cmd, file=out_fh)
            ret = subprocess.run(cmd, stdout=out_fh, stderr=out_fh)

            if self.max_fasterq > 0:
                self.fasterq_semaphore.release()
            subprocess.run(["df", "-h"], stdout=out_fh)

            if ret.returncode != 0:
                print(f"fasterqdump of {sra} failed with {ret.returncode} {cmd}", file=out_fh)
                return None
        fq_files = self.find_fq_files()
        if fq_files is not None:
            return fq_files, True
        return None
    
    def find_fq_files(self):

        for suffix in ('fastq', 'fastq.gz', 'fq.gz'):
            print(f"check {suffix}")
            fq_files = glob.glob(f"{self.path}/*.{suffix}")
            print(f"files: {self.path} {fq_files}")
            if len(fq_files) == 1 or len(fq_files) == 2:
                fq_files.sort();
                return fq_files
            elif len(fq_files) == 3:
                fq_files = glob.glob(f"{self.path}/*_[12].{suffix}")
                fq_files.sort();
                return fq_files

