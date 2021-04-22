## AWS via cloudyR packages

This script uses the [rtweet](https://github.com/ropensci/rtweet) package and several packages from the [cloudyR project](https://cloudyr.github.io/) to create simple reports on Twitter activity. To run the script, you'll need access keys from both Twitter and Amazon.  
  
The script streams a sample of real-time tweets from a specified location, and passes those tweets on to **AWS Comprehend** and **AWS Translate** for language detection, translation, entity detection, and sentiment analysis. Some filtering is used to determine which entities are worth studying. Visualizations in the script create simple graphics which answer the following questions for the user:  
+ What languages are being used on Twitter in this location?  
+ What is the general sentiment within the language groups?  
+ What entities (people, organizations, etc.) are being discussed, and what is the general sentiment associated with those entities?  
+ What languages are these entities being discussed in?  

You can read more about how the script works at [this blog post](https://joyce-john.medium.com/whats-up-on-twitter-monitoring-public-discourse-with-aws-and-r-892e68953d17).  
  
### Example graphs from a sample collected from London:  
  
![london_lang](/charts/london_sample/1_london_lang_dist.png)
  
![london_sent](/charts/london_sample/2_london_sent_dist.png)
  
![london_ent_sent](/charts/london_sample/3_london_entity_sent.png)

![london_ent_lang](/charts/london_sample/4_london_entity_lang.png)