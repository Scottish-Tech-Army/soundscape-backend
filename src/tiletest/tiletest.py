import argparse
import csv
import datetime
import json
import logging
import math
import os
import random
import requests
import sys
import time

# This is the test tooling for the tile server.
# Set up parser at top for readability
parser = argparse.ArgumentParser(description='Test tooling for tile server testing')
parser.add_argument('--base-url', type=str, help='Base URL', required=True)
parser.add_argument('--count', type=int, help='Number of requests to issue; 0 for run through entire file', default=0)
parser.add_argument('--report-every', type=int, help='Report every N tests', default=50)
parser.add_argument('--log-level', type=str, help='Log level', default='info')
parser.add_argument('--output', type=str, help='Output directory', default='/tmp')
parser.add_argument('--shuffle', action='store_true', help='Shuffle order of test cases')
parser.add_argument('--casesfile', type=str, help='CSV file of test cases', default='all-cities-with-population.csv') # from https://www.geoapify.com/most-populated-cities-in-the-world/
parser.add_argument('--sleep', type=int, help='Sleep this many seconds after each request', default=0)

# Set up the logger globally
logger = logging.getLogger()

class Summary:
    def __init__(self):
        self.total = 0
        self.success = 0
        self.errors = 0
        self.total_time_ms = 0

    def add_result(self, success, time_ms=None):
        if success:
            self.success += 1
        else:
            self.errors += 1
        self.total += 1

        if success:
            self.total_time_ms += time_ms

    def report(self):
        if self.total == 0:
            avg_time = 0
        else:
            avg_time = self.total_time_ms / self.total

        logger.info("Total tests: %d", self.total)
        logger.info("Successful tests: %d", self.success)
        logger.info("Errored tests: %d", self.errors)
        logger.info("Average time (ms): %.2f", avg_time)

class OutputRecorder:
    def __init__(self, output_dir):
        logger.info("Initializing output file in %s", output_dir)
        if not os.path.exists(output_dir):
            logger.error("Output directory %s does not exist.", args.output)
            raise NotADirectoryError(f"Output directory {output_dir} does not exist.")
        if not os.path.isdir(output_dir):
            logger.error("Output path %s is not a directory.", output_dir)
            raise NotADirectoryError(f"Output directory {output_dir} is not a directory.")

        timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d_%H%M%S")
        self.csv_filename = os.path.join(output_dir, f"tiletest_{timestamp}.csv")
        logger.info("CSV output file will be: %s", self.csv_filename)

        with open(self.csv_filename, 'w') as f:
            writer = csv.writer(f)
            writer.writerow(["time", "name", "country", "url", "retcode", "time_ms", "data_size", "error"])

    def record(self, name, country, url, retcode, time_ms, data_size, error=None):
        with open(self.csv_filename, 'a') as f:
            timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
            writer = csv.writer(f)
            writer.writerow([timestamp, name, country, url, retcode, time_ms, data_size, error if error else ""])

    def record_summary(self, summary: Summary):
        with open(self.csv_filename, 'a') as f:
            writer = csv.writer(f)
            writer.writerow([])
            writer.writerow(["Total tests", summary.total])
            writer.writerow(["Successful tests", summary.success])
            writer.writerow(["Errored tests", summary.errors])
            writer.writerow(["Total time (ms)", summary.total_time_ms])
            if summary.total == 0:
                avg_time = 0
            else:
                avg_time = summary.total_time_ms / summary.success
            writer.writerow(["Average time for successes (ms)", f"{avg_time:.2f}"])

def read_test_cases(cases_file, shuffle=False):
    logger.info("Reading test cases from %s", cases_file)
    test_cases = []
    with open(cases_file, newline='') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            test_cases.append(row)

    if shuffle:
        logging.info("Shuffling test cases")
        random.shuffle(test_cases)

    return test_cases

def get_xy_tile(latitude, longitude, zoom=16):
    # Get tile coordinates from lat/long
    lat_rad = math.radians(latitude)
    n = 1 << zoom
    x_tile = int(math.floor((longitude + 180) / 360 * n))
    y_tile = int(math.floor((1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2 * n))

    x_tile = max(0, min(x_tile, n - 1))
    y_tile = max(0, min(y_tile, n - 1))

    return x_tile, y_tile

def run_test_cases(args, test_cases, recorder):
    logger.info("Running test cases")
    num_tests = args.count

    if args.count > len(test_cases) or args.count == 0:
        num_tests = len(test_cases)

    logger.info("Test cases to run: %d", num_tests)
    summary = Summary()

    for i in range(num_tests):
        run_single_test_case(args, test_cases[i], summary=summary, recorder=recorder)

        if (i + 1) % args.report_every == 0:
            logger.info("Completed %d of %d tests", i + 1, num_tests)
            summary.report()

        if args.sleep:
            logger.debug("Sleeping for %d seconds", args.sleep)
            time.sleep(args.sleep)

    logger.info("All tests completed.")
    summary.report()
    recorder.record_summary(summary)

def run_single_test_case(args, test_case, summary, recorder):
    try:
        latitude = float(test_case['latitude'])
        longitude = float(test_case['longitude'])
        x_tile, y_tile = get_xy_tile(latitude, longitude)

        url = f"{args.base_url}/16/{x_tile}/{y_tile}.json"
        logger.debug("URL: %s", url)
    except KeyError:
        logger.error("Test case is missing required fields: %s", test_case)
        raise

    start_time = datetime.datetime.now()
    error = None
    retcode = None
    data_size = 0

    try:
        response = requests.get(url)
        retcode = response.status_code
        data = response.content
        data_size = len(data)
        if retcode == 200:
            try:
                json_data = response.json()
            except Exception as e:
                error = f"Invalid JSON: {e}"
                retcode = -1
        else:
            error = response.text
    except Exception as e:
        error = str(e)
        retcode = -1

    end_time = datetime.datetime.now()
    time_ms = int((end_time - start_time).total_seconds() * 1000)

    recorder.record(
        test_case['name'],
        test_case['country'],
        url,
        retcode,
        time_ms,
        data_size,
        error
    )

    summary.add_result(error is None and retcode == 200, time_ms)

if __name__ == '__main__':
    args = parser.parse_args()
    loglevel = args.log_level.upper()
    logging.basicConfig(level=loglevel, format='%(asctime)s:%(levelname)s:%(message)s')
    logger.setLevel(loglevel)
    logger.warning('Test tooling started')

    test_cases = read_test_cases(args.casesfile, args.shuffle)
    recorder = OutputRecorder(args.output)
    run_test_cases(args, test_cases, recorder)
