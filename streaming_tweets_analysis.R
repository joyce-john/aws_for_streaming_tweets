###################################################################
#############          LOAD LIBRARIES       #######################
###################################################################

# install.packages("rtweet")
library(rtweet)
# install.packages("aws.comprehend", repos = c(cloudyr = "http://cloudyr.github.io/drat", getOption("repos")))
library("aws.comprehend")
# install.packages("aws.translate", repos = c(getOption("repos"), "http://cloudyr.github.io/drat"))
library("aws.translate")
# install.packages("tidyverse")
library(tidyverse)


###################################################################
############# LOAD KEYS FOR TWITTER AND AWS #######################
###################################################################

# load AWS keys - load your own keys below
keyTable <- read.csv("accessKeys.csv", header = T) # accessKeys.csv == the CSV downloaded from AWS containing your Acces & Secret keys
AWS_ACCESS_KEY_ID <- as.character(keyTable$Access.key.ID)
AWS_SECRET_ACCESS_KEY <- as.character(keyTable$Secret.access.key)

#activate AWS
Sys.setenv("AWS_ACCESS_KEY_ID" = AWS_ACCESS_KEY_ID,
           "AWS_SECRET_ACCESS_KEY" = AWS_SECRET_ACCESS_KEY,
           "AWS_DEFAULT_REGION" = "eu-west-1") 


# load Twitter API keys and tokens - write your own keys below
consumerKey <- ""
consumerSecret <- ""
accessToken <- ""
accessTokenSecret <- ""

# create token an OAuth token for accessing twitter stream
create_token(
  app = "",
  consumer_key = consumerKey,
  consumer_secret = consumerSecret,
  access_token = accessToken,
  access_secret = accessTokenSecret,
  set_renv = TRUE
)

# load the Twitter OAuth token 
token <- get_token()

# delete sensitive Twitter credentials from the environment
rm(accessToken, accessTokenSecret, consumerKey, consumerSecret)


###################################################################
#############     COLLECT STREAMING TWEETS       ##################
###################################################################


# stream random sample of current tweets for x seconds and load into a dataframe
df <- stream_tweets(
  lookup_coords("london"), # you can specify a location if you want - see rtweet:::citycoords %>% view() for recognized cities
  timeout = 120, 
  parse = TRUE,
  token = NULL,
  verbose = TRUE
)


# there are 90 variables, but we are only doing anonymous sentiment analysis
# so just grab the text and and forget about everything else
raw_tweets <- df %>% pull(text)


###################################################################
###########     CREATE AWS ANALYSIS FUNCTIONS     #################
###################################################################

# These custom functions trim the output of the information that cloudyR's AWS functions return.


# create a function which sends the text to AWS through detect_language()
# detect_language() returns a dataframe, which includes a ranked list of likely languages
# use slice_head() to only select the top (most likely) language in the list, and pull(LanguageCode) to select only that column
# and return only the language code
language_label <- function(text){
  detect_language(text) %>% slice_head() %>%  pull(LanguageCode)
}


# create a function which translates text to English using the supplied language code
# and returns only the English text
translate_to_english <- function(LanguageCode, text){
  translate(text, from = LanguageCode, to = "en") %>% str_extract(".*")
}

# create a function which detects the entities present in the English version of the tweet
# and returns only a character vector of those entities
# detect_entities() will return a data.frame if it finds entities, and a matrix/array if it doesn't
# this function returns a character vector either way
entity_label <- function(text){
  testvar <- detect_entities(text) # assign the output of detect_entities to a test variable
  
  if (class(testvar) == "data.frame"){ # if it detects any entities, it will return a DF, and we grab the list  of entities with pull() as a character vector
    returnvar <- testvar %>% pull(Text)
  }else{
    returnvar <- "" # if it doesn't detect any entities the class of the output will not be a DF, and we will return nothing
  }
  return(returnvar)
}


# create a function which scores the sentiment of the translated text
# and returns only the simple sentiment label
sentiment_label <- function(text){
  detect_sentiment(text) %>% pull(Sentiment)
}


###################################################################
##############      ANALYZE TWEETS ON AWS        ##################
###################################################################

# AWS batch size limits don't allow us to store all the information in a DF and call AWS functions within mutate()
# so call the AWS functions one-by-one and store the output in vectors/lists

languages <- unname(sapply(raw_tweets, language_label))

english_text <- unname(mapply(translate_to_english, languages, raw_tweets))

entities <- sapply(english_text, entity_label)

sentiment <- unname(sapply(english_text, sentiment_label))


###################################################################
###############     CLEAN AND WRANGLE RESULTS     #################
###################################################################


###################
##      TIDY     ##
##  DATAFRAME    ##
###################


# make a neat dataframe with most of the variables
# entities is a tricky list that makes our data less tidy, so it will go into a different DF
df <- data.frame(languages = as.factor(languages), english_text = english_text, sentiment = as.factor(sentiment))

# add an ID variable which will make joining easy
df <- df %>% mutate(id = row_number())


###################
##  MEANINGFUL   ##
##  ENTITY LIST  ##
###################

# Create a list of entities worth studying. This list is used for filtering entity_df later.
# This is a list of entities which meet three criteria:
# 1: they are not the @ symbol (sometimes detected as an entity) or an empty string (a return from my custom function)
# 2: they appear more than once in the sample (helpful criterion for small tweet samples)
# 3: they comprise at least 1% of the sample - or another value that you set (helpful criterion for big tweet samples)

# create a character vector of all the entities
entities_unlisted <- unname(unlist(entities))

# filter out entities which are empty strings or @ symbols
entities_filtered <- entities_unlisted[entities_unlisted!= "" & entities_unlisted!= "@"]

# find the index positions of entities which appear in the sample more than once with duplicated()
repeat_vals_index <- duplicated(entities_filtered)

# this creates a list of repeated entities - it eliminates every entity only mentioned once
entities_meaningful <- entities_filtered[repeat_vals_index]

# In what percentage of tweets must an entity be present? I set the cutoff to 1%, but you can choose your own value.
percentage_for_relevance <- 0.01

# this filters the list of entities further to only include those which comprise at least 1% of the sample
entities_meaningful <-
  data.frame(entities_meaningful = entities_meaningful) %>% 
  group_by(entities_meaningful) %>% 
  count() %>% 
  filter(n >= (percentage_for_relevance * nrow(df))) %>% 
  pull(entities_meaningful)

# we can take a quick look at these recurring entities
entities_meaningful


###################
##    ENTITY     ##
##   DATAFRAME   ##
###################

# Every row represents one unique observation of an entity...
# ...and also the variables associated with the tweet in which it was detected
# the other variables (languages, english_text, sentiment, id) will be repeated for every entity which
# was detected in a single tweet
# only use this dataframe for counting entities - do not use it for counting the other variables!


# give every tweet in the list an ID, which will be necessary for joining after we flatten the list
# add the decimal point as part of an ugly workaround for unlist()'s behavior of renaming duplicates
names(entities) <- paste0(seq_along(entities),".")

# flatten the list and make a dataframe of entities and IDs which link them to tweet
entity_df <- data.frame(entity = unname(unlist(entities)), id = (names(unlist(entities))))

# unlist() has renamed duplicate IDs by adding another digit after the decimal point
# but we **want** duplicate IDs - one tweet has many entities! Therefore, one tweet may be represented many times by the same ID
# use some string manipulation to strip the decimal and following characters, properly reinstating duplicate IDs
entity_df <- entity_df %>% mutate(id = as.numeric(str_replace(id, "\\.\\d*",  "")))

# lets make a long joined DF - there is a one-to-many relationship between tweets/IDs and entities
# so this DF will be much longer than the number of tweets we scraped
entity_df <- right_join(df, entity_df, by = "id")

# reorder the levels of the sentiment factor to help make plot legends easy to understand
entity_df$sentiment <- factor(entity_df$sentiment, levels = c("POSITIVE", "NEUTRAL", "MIXED", "NEGATIVE"))


###################################################################
###############            VISUALIZATION          #################
###################################################################


# frequency of languages in the sample
df %>% 
  ggplot(aes(x = languages)) +
  geom_histogram(stat = "count") +
  labs(x = "language", y = "count", title = "Languages Detected in the Sample") +
  theme(plot.title = element_text(hjust = 0.5))

# frequency of sentiments within the sample, colored by language
df %>% 
  ggplot(aes(x = sentiment, fill = languages)) + 
  geom_bar(stat = "count") +
  labs(title = "Sentiments Detected, with Associated Languages") +
  theme(plot.title = element_text(hjust = 0.5))

# plot of meaningful entities, colored by sentiment, from the entity_df
entity_df %>% 
  filter(entity %in% entities_meaningful) %>% 
  group_by(entity) %>%
  ggplot(aes(x = entity, fill = sentiment)) +
  geom_bar(stat = "count") +
  scale_fill_manual(values = c("#2ca330", "#929692", "#c4c728", "#bf2a24")) +
  labs(title = "Entities Detected, with Associated Sentiment") +
  theme(plot.title = element_text(hjust = 0.5), axis.text.x = element_text(angle = 90, hjust = 1))

# plot of meaningful entities, colored by original language of the tweet, from the entity_df
entity_df %>% 
  filter(entity %in% entities_meaningful) %>% 
  group_by(entity) %>% 
  ggplot(aes(x = entity, fill = languages)) +
  geom_bar(stat = "count") +
  labs(title = "Entities Detected, Color-coded by Language") +
  theme(plot.title = element_text(hjust = 0.5), axis.text.x = element_text(angle = 90, hjust = 1))



