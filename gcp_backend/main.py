import base64
import json
import logging
from google.cloud import firestore
import functions_framework

# Initialize Firestore client globally
db = firestore.Client()
COLLECTION_NAME = 'edge_alerts'

@functions_framework.cloud_event
def process_edge_alert(cloud_event):
    """
    Cloud Function triggered by a Pub/Sub message.
    Args:
         cloud_event (functions_framework.CloudEvent): The CloudEvent representing the Pub/Sub message.
    """
    logging.info(f"Received event with ID: {cloud_event['id']}")
    
    # Check if data exists
    if 'message' not in cloud_event.data:
         logging.error("No valid message payload found in the event.")
         return
         
    # Decode the base64 Pub/Sub payload
    pubsub_message = cloud_event.data['message']
    
    try:
        # data is stored as a base64 encoded string
        payload_str = base64.b64decode(pubsub_message['data']).decode('utf-8')
        alert_payload = json.loads(payload_str)
        logging.info(f"Successfully decoded JSON payload for device: {alert_payload.get('device_id', 'UNKNOWN')}")
    except Exception as e:
        logging.error(f"Failed to decode or parse Pub/Sub message data: {e}")
        return

    # In a full production system, we would validate against alerts_schema.json here.
    
    # Store the parsed document in Firestore
    try:
        doc_ref = db.collection(COLLECTION_NAME).document() # Auto-generate ID
        doc_ref.set(alert_payload)
        logging.info(f"Successfully stored alert in Firestore document {doc_ref.id}.")
        
        # Phase 2 Placeholder: Trigger Firebase Cloud Messaging (FCM) based on severity
        if alert_payload.get('severity_level') in ['High', 'Critical']:
            logging.warning(f"HIGH SEVERITY ALERT RECEIVED! Forwarding to clinician notification service...")
            # push_notification_service.send(alert_payload)
            
    except Exception as e:
        logging.error(f"Error storing document in Firestore: {e}")
        raise e
