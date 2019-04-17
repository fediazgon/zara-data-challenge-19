# Uncomment the following lines to install the required libraries
# If you see an error like 'there is no package called '<package>'' try to install it manually from the package manager
# install.packages('rBayesianOptimization')
# devtools::install_github('robjhyndman/M4metalearning')
# devtools::install_github('pmontman/tsfeatures')
# devtools::install_github('pmontman/customxgboost')

library(M4metalearning)
library(tsfeatures)
library(xgboost)

data_in = file.path('data', 'preprocessed')
data_out = file.path('data', 'model')

csv_filename = 'revenue_blocks_day_0_day_84.csv'
suffix = 'blocks'  # Suffix to add to saved file (i.e., data, hyperparameters). Useful to avoid overwriting multiple runs

csv_path = file.path(data_in, csv_filename)
hyper_path = file.path(data_out, ifelse(is.null(suffix), 'ZARA_rev_hyper.Rds', paste('ZARA_rev_hyper_', suffix, '.RData', sep = '')))
model_path = file.path(data_out, ifelse(is.null(suffix), 'ZARA_rev_model.Rds', paste('ZARA_rev_model_', suffix, '.Rds', sep = '')))

N_CORES = 7  # number of cores to use in parallelizable functions
TRAIN_FIRST = TRUE
MAX_SERIES = -1  # maximum number of series used to train, -1 to use ALL (might be less due to sanity checks)
N_ITER_HYPER = 100  # number of iterations for hyperparameter search (bayesian optimization)

FH = 7  # forecasting horizon (week) DO NOT CHANGE! Or change it. I am a warn, not a cop.

parse_data <- function(file, forecasting_horizon = 7, max_rows = -1, skip_short = TRUE, skip_zeroes = TRUE) {
  data = list()
  csv = read.csv(file, sep = ';', header = TRUE, row.names = 1, stringsAsFactors = FALSE)
  row_names = row.names(csv)
  max_rows = ifelse(max_rows > 0, max_rows, nrow(csv))
  skipped_short = 0
  skipped_zeroes = 0
  for (row_idx in 1:max_rows) {
    data_fields = list()
    row = as.numeric(csv[row_idx,])
    first_index = min(which(!is.na(row)))  # first non-NAN index
    last_index = length(row)
    # Skip series with less observations than the number of points to predict
    n = last_index - first_index + 1
    if (skip_short && n <= forecasting_horizon + 1) {
      cat('Skipping time series', row_names[[row_idx]], ' -- too short\n')
      skipped_short = skipped_short + 1
      next
    }
    series = ts(row[first_index:last_index], start = first_index, end = last_index, frequency = 1)
    series[is.na(series)] = 0
    # Was getting NANs during forecasting either when the input to the model or the true forecasting were all zeroes  
    if (skip_zeroes && (sum(head(series, length(series) - forecasting_horizon)) == 0 || sum(tail(series, forecasting_horizon)) == 0)) {
      cat('Skipping time series', row_names[[row_idx]], ' -- too many zeros\n')
      skipped_zeroes = skipped_zeroes + 1
        next
    }
    series[series < 0.1] = 0.001
    data_fields[['id']] = row_names[[row_idx]]
    data_fields[['x']] = series
    data_fields[['n']] = n
    data_fields[['h']] = forecasting_horizon
    real_index = row_idx - skipped_short - skipped_zeroes
    data[[real_index]] = data_fields
  }
  if (skip_short) {
    cat('Skipped', skipped_short, 'time series with less than', forecasting_horizon, 'values\n')
  }
  if (skip_zeroes) {
    cat('Skipped', skipped_zeroes, 'time series with too many zeros\n')
  }
  data
}

if (TRAIN_FIRST) {
  cat('***** TRAINING MODEL FIRST *****\n')
  # Parse CSV file to load information about the time series (id, observations, length, forecasting horizon)
  cat('** Parsing data from', csv_path, '**\n')
  ZARA_rev <- parse_data(csv_path, forecasting_horizon = FH, max_rows = MAX_SERIES, skip_short = TRUE, skip_zeroes = TRUE)
  
  # Create the new version of the dataset by removing the last observations of each series and set them as the ground truth
  ZARA_rev <- temp_holdout(ZARA_rev)
  
  # Apply the forecasting methods to each series (this takes a while and there is no way to check the progress)
  # Took 10mins (2434 blocks) in a i7-8650U
  cat('** Applying forecasting methods to', length(ZARA_rev), 'time series (this might take a while) **\n')
  system.time(ZARA_rev <- calc_forecasts(ZARA_rev, forec_methods(), n.cores = N_CORES))
  
  # Calculate the errors of each forecasting method
  ZARA_rev <- calc_errors(ZARA_rev)
  
  # Extract features from each series
  cat('** Extracting features from time series **\n')
  ZARA_rev <- THA_features(ZARA_rev, n.cores = N_CORES)
  len_before = length(ZARA_rev)
  # Some series might produce an error while computing the features. Ignore those
  ZARA_rev = ZARA_rev[sapply(ZARA_rev, function(x) is.null(x$message))]
  len_after = length(ZARA_rev)
  cat('** Removed', len_before - len_after, 'time series that threw erros while computing features **\n')
  
  # Search for hyperparameters (this takes A LOT)
  cat('** Hyperparameter search (go play outside) **\n')
  system.time(hyperparameter_search(ZARA_rev, filename = hyper_path, n_iter = N_ITER_HYPER, n.cores = N_CORES))
  cat('** Saving hyperparameters in', hyper_path, '**\n')
  
  # Create training set for xgboost
  train_data <- create_feat_classif_problem(ZARA_rev)
  # Set training hyperparameters
  load(hyper_path)
  best_hyper <- bay_results[which.min(bay_results$combi_OWA),]
  param <- list(max_depth = best_hyper$max_depth,
                eta = best_hyper$eta,
                nthread = N_CORES,
                silent = 0,
                objective = error_softmax_obj,
                num_class = ncol(train_data$errors),  # the number of forecast methods used
                subsample = bay_results$subsample,
                colsample_bytree = bay_results$colsample_bytree)
  # Train with xgboost
  meta_model <- train_selection_ensemble(train_data$data,
                                         train_data$errors,
                                         param = param)
  cat('** Saving xgboost model in', model_path, '**\n')
  saveRDS(meta_model, file = model_path)
}

meta_model <- readRDS(model_path)
# Read the data again, since now the validation set is to necessary
ZARA_rev_final = parse_data(csv_path, forecasting_horizon = FH, max_rows = -1, skip_short = FALSE, skip_zeroes = FALSE)
# Just calculate the forecast and features
cat('** Calculating forecasts and features (this might take a while) **')
ZARA_rev_final <- calc_forecasts(ZARA_rev_final, forec_methods(), n.cores = N_CORES)
ZARA_rev_final <- THA_features(ZARA_rev_final, n.cores = N_CORES)
len_before = length(ZARA_rev_final)
# Some series might produce an error while computing the features. Ignore those
ZARA_rev_final = ZARA_rev_final[sapply(ZARA_rev_final, function(x) is.null(x$message))]
len_after = length(ZARA_rev_final)
cat('** Removed', len_before - len_after, 'time series that threw erros while computing features **\n')
# Get the feature matrix
final_data <- create_feat_classif_problem(ZARA_rev_final)
# Calculate predictions
preds <- predict_selection_ensemble(meta_model, final_data$data)
# Calculate the final mean forecasts
ZARA_rev_final <- ensemble_forecast(preds, ZARA_rev_final)

# Create dataset with predictions
start_day_in = 0
final_day_in = length(read.csv(csv_path, sep = ';', header = TRUE, row.names = 1, nrows = 0)) - 1
final_day_forecast = final_day_in + FH
dataset_predictions = matrix(nrow = length(ZARA_rev_final), ncol = final_day_forecast + 1)
colnames(dataset_predictions) = c(sapply(start_day_in:final_day_in, function (x) paste('X', x, sep = '')), 
                                  sapply((final_day_in + 1):final_day_forecast, function (y) paste('Y', y, sep = '')))
ids <- vector('list', nrow(dataset_predictions))

for (i in 1:length(ZARA_rev_final)) {
  series_data <- ZARA_rev_final[[i]]
  ids[[i]] <- series_data$id
  x <- rep(NA, ncol(dataset_predictions))
  series <- series_data$x
  start <- start(series)[[1]]
  end <- end(series)[[1]]
  x[start:end] <- series
  x[(final_day_in + 2):(final_day_forecast + 1)] <- round(series_data$y_hat, digits = 2)
  dataset_predictions[i,] <- x 
}
rownames(dataset_predictions) <- ids
predictions_path = file.path(data_out,ifelse(is.null(suffix), 
                                             paste('predictions_day_0_day_', final_day_forecast, '.csv', sep = ''),
                                             paste('predictions_', suffix, '_day_0_day_', final_day_forecast, '.csv', sep = '')))
cat('** Saving predictions in', predictions_path, '**\n')
write.table(dataset_predictions, file = predictions_path, row.names = TRUE, col.names = NA, dec = '.', sep = ';', quote = FALSE)
