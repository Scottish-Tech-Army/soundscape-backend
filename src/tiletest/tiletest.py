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

# This is the test tooling for the tile server.
# Set up parser at top for readability
parser = argparse.ArgumentParser(description='Test tooling for tile server testing')
parser.add_argument('--base-url', type=str, help='Base URL', required=True)
parser.add_argument('--count', type=int, help='Number of requests to issue; 0 for run through entire file', default=0)
parser.add_argument('--report-every', type=int, help='Report every N tests', default=10)
parser.add_argument('--log-level', type=str, help='Log level', default='info')
parser.add_argument('--output', type=str, help='Output directory', default='/tmp')
parser.add_argument('--shuffle', action='store_true', help='Shuffle order of test cases')
parser.add_argument('--casesfile', type=str, help='CSV file of test cases', default='all-cities-with-population.csv') # from https://www.geoapify.com/most-populated-cities-in-the-world/
parser.add_argument('--countryfile', type=str, help='CSV file of countries', default='countries.csv')
parser.add_argument('--includedonly', action='store_true', help='Only test included countries')

# Set up the logger globally
logger = logging.getLogger()

class Summary:
    def __init__(self):
        self.total = 0
        self.success = 0
        self.errors = 0
        self.success_included = 0
        self.success_excluded = 0
        self.error_included = 0
        self.error_excluded = 0
        self.total_time_ms = 0

    def add_result(self, included, success, time_ms=None):
        if success:
            self.success += 1
            if included:
                self.success_included += 1
            else:
                self.success_excluded += 1
        else:
            self.errors += 1
            if included:
                self.error_included += 1
            else:
                self.error_excluded += 1
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

        timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%y%m%d_%H%M%S")
        self.csv_filename = os.path.join(output_dir, f"tiletest_{timestamp}.csv")
        logger.info("CSV output file will be: %s", self.csv_filename)

        with open(self.csv_filename, 'w') as f:
            writer = csv.writer(f)
            writer.writerow(["name", "country", "included", "url", "retcode", "time_ms", "data_size", "error"])

    def record(self, name, country, included, url, retcode, time_ms, data_size, error=None):
        with open(self.csv_filename, 'a') as f:
            writer = csv.writer(f)
            writer.writerow([name, country, included, url, retcode, time_ms, data_size, error if error else ""])

    def record_summary(self, summary: Summary):
        with open(self.csv_filename, 'a') as f:
            writer = csv.writer(f)
            writer.writerow([])
            writer.writerow(["Total tests", summary.total])
            writer.writerow(["Successful tests", summary.success])
            writer.writerow(["Successful tests (included)", summary.success_included])
            writer.writerow(["Successful tests (excluded)", summary.success_excluded])
            writer.writerow(["Errored tests", summary.errors])
            writer.writerow(["Errored tests (included)", summary.error_included])
            writer.writerow(["Errored tests (excluded)", summary.error_excluded])
            writer.writerow(["Total time (ms)", summary.total_time_ms])
            if summary.total == 0:
                avg_time = 0
            else:
                avg_time = summary.total_time_ms / summary.success
            writer.writerow(["Average time for successes (ms)", f"{avg_time:.2f}"])


def read_test_cases(cases_file, country_file, shuffle=False):
    logger.info("Reading test cases from %s", cases_file)
    test_cases = []
    with open(cases_file, newline='') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            test_cases.append(row)

    if shuffle:
        logging.info("Shuffling test cases")
        random.shuffle(test_cases)

    countries = {}
    with open(country_file, newline='') as csvfile:
        reader = csv.DictReader(csvfile)
        for row in reader:
            country = row['Country']
            included = row['Included'].lower()
            if included == 'true':
                countries[country] = True
            elif included == 'false':
                countries[country] = False
            else:
                logger.error("Invalid value (%s) for included for %s in countries file %s", included, country, country_file)
                raise ValueError(f"Invalid value ({included}) for included for {country} in countries file {country_file}")

    # Now clean up some data
    unmatched = []
    final_cases = []

    for case in test_cases:
        country = case['country']
        if country in unmatched:
            # Already know this country is unmatched
            continue
        if country not in countries:
            unmatched.append(country)
            logger.warning("Throwing out country %s as not in countries file", country)
            continue

        case['included'] = countries[country]

        if args.includedonly and not case['included']:
            continue

        final_cases.append(case)

    return final_cases

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
    except Exception as e:
        error = str(e)
        retcode = -1

    if error is None and retcode == 200:
        try:
            json.loads(data)
        except Exception as e:
            error = f"Invalid JSON: {e}"
            retcode = -1

    end_time = datetime.datetime.now()
    time_ms = int((end_time - start_time).total_seconds() * 1000)

    recorder.record(
        test_case['name'],
        test_case['country'],
        test_case['included'],
        url,
        retcode,
        time_ms,
        data_size,
        error
    )

    summary.add_result(test_case['included'], error is None and retcode == 200, time_ms)

if __name__ == '__main__':
    args = parser.parse_args()
    loglevel = args.log_level.upper()
    logging.basicConfig(level=loglevel, format='%(asctime)s:%(levelname)s:%(message)s')
    logger.setLevel(loglevel)
    logger.warning('Test tooling started')

    test_cases = read_test_cases(args.casesfile, args.countryfile, args.shuffle)
    recorder = OutputRecorder(args.output)
    run_test_cases(args, test_cases, recorder)
