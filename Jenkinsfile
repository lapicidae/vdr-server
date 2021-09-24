//
// Plugin "build user vars" is needed!
// Set "Manage Jenkins -> Configure System -> Global properties" "DEFAULT_EMAIL" Environment variable for users without email address!
//

pipeline {
	environment {
		registry = "lapicidae/vdr-server"
		registryCredential = 'dockerhub'
		registryTag = 'latest'
		//gitURL = 'https://github.com/lapicidae/vdr-server.git'
		currTime = sh(returnStdout: true, script: 'date +"%H:%M"').trim()
		currDate = sh(returnStdout: true, script: 'date +"%m.%d.%Y"').trim()
		dockerImage = ''
		email = ''
	}
	agent any
	stages {
		stage('Init') {
			steps{
				echo 'Initializing....'
				script {
					user = wrap([$class: 'BuildUser']) { return env.BUILD_USER }
					user_id = wrap([$class: 'BuildUser']) { return env.BUILD_USER_ID }
					email = wrap([$class: 'BuildUser']) { return env.BUILD_USER_EMAIL }
					if (!email?.trim()) {
						email = "${DEFAULT_EMAIL}"
					}
				}
				echo "--- User Info ---"
				echo "User:\t\t$user"
				echo "User ID:\t$user_id"
				echo "eMail:\t\t$email"
				echo "Time:\t\t$currTime"
				echo "Date:\t\t$currDate"
			}
		}
		stage('Clone') {
			steps{
				echo 'Cloning....'
				checkout scm
				//git gitURL
			}
		}
		stage('Build') {
			steps{
				echo 'Building....'
				script {
					dockerImage = docker.build registry + ":$BUILD_NUMBER"
				}
			}
		}
		stage('Publish') {
			steps{
				echo 'Publishing....'
				script {
					docker.withRegistry( '', registryCredential ) {
						dockerImage.push(registryTag)
					}
				}
			}
		}
		stage('Clean') {
			steps{
				echo 'Cleaning....'
				sh "docker rmi $registry:$BUILD_NUMBER || echo Failed to remove image $registry:$BUILD_NUMBER."
				sh "docker rmi $registry:$registryTag || echo Failed to remove image $registry:$BUILD_NUMBER."
			}
		}
	}
	post {
		always {
			echo "Build result => ${currentBuild.result}"
			mail to: "$email",
			  subject: "Pipeline: ${currentBuild.fullDisplayName} -> ${currentBuild.result}",
			  charset: 'UTF-8',
			  mimeType: 'text/html',
			  body: "<b>${env.JOB_NAME} - Build #${env.BUILD_NUMBER} - <em>${currentBuild.result}</em></b><br/><br/>Job started by user ${user_id} (${user}) at ${currTime} on ${currDate}.<br/>Build took ${currentBuild.durationString}.<br/><br/>Check console <a href='${env.BUILD_URL}console'>output</a> to view full results.<br/><br/>Your faithful employee<br/><em>Node</em> ${env.NODE_NAME}"
		}
	}
}
